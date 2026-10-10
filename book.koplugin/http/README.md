 # http/ — 唯一网络栈

禁止 `socket.http` / luasocket 超时路径。缓存表在 [`cache.lua`](cache.lua)。

## 设计

全部外部 HTTP 经 Turbo 非阻塞回调。可取消句柄统一 `{ cancel }`。GET 的 `cache_ttl>0` 走 `http` 表（带 `auth_username` 时按用户隔离）。`online/` 自己管文件 TTL（`cache/online/`），请求一律 `cache_ttl = 0`。

入口只检查网卡状态（`NetworkMgr:isConnected`），禁用 `isOnline`：它在 UI 线程同步解析 DNS。

| 路径 | 职责 |
|------|------|
| `request/init.lua` | 对外入口 `http.request`：request / get / post / stream / download / ok / header |
| `request/stream.lua` | 流式读取（改写 turbo 读路径，不攒整段 body），经 `Request.stream` 暴露 |
| `request/fetch.lua` | request 与 stream 共用：开请求（查网络、占泵）、fetch 参数、取消拆连接 |
| `request/header.lua` | 默认请求头 `http.request.header` |
| `turbo/init.lua` | 自建 ioloop 与按需泵（acquire / release）、建 HTTPClient |
| `turbo/patch.lua` | turbo 类补丁（SNI、CA、connect_fail、int64）+ 主机名 DNS 缓存 |
| `proxy/init.lua` | KOReader HTTP 代理（http 绝对 URI / https CONNECT 隧道） |
| `proxy/setting.lua` | 网络设置页（HTTP 代理）`http.proxy.setting` |
| `cache.lua` | 响应缓存：`key` / `fetch`（先读缓存再请求，成功才写） / `clear` |
| `webdav.lua` | WebDAV 客户端 |

自己解析回包的客户端（moon / zlib）用 `Cache.fetch(key, ttl, load, cb)` 缓存解码后的结果，别再手写「读缓存 → 请求 → 写缓存」。

## 用法

```lua
local Request = require("http.request")

local h = Request.get(url, {
    headers = { Authorization = "…" },
    cache_ttl = 3600,
    timeout = 20,
}, function(body, err, res)
    -- 成功：body 为响应体字符串，err 为 nil；失败：body 为 nil，err 为原因
    -- 需要状态码 / 响应头时看第三参 res
    if not body then return end
end)

Request.post(url, body, { headers = … }, cb)  -- 回调同 get：cb(body, err, res)
Request.download({ url = url }, dest_path, cb)
Request.stream({ url = url }, {
    on_headers = function(code, headers) end,
    on_data = function(chunk) end,
    on_done = function(err) end,  -- err 为 nil 表示成功收完
})

h.cancel()
require("http.cache").clear("example.com")  -- 可选 substr
```

日志里的 URL 会剥 query/fragment/userinfo。
