# http/ — 唯一网络栈

路径：[`book.koplugin/http/`](../../book.koplugin/http/)。禁止 `socket.http` / luasocket 超时路径。缓存表见 [`../db/http.md`](../db/http.md)。

## 设计

全部外部 HTTP 经 Turbo 非阻塞回调。可取消句柄统一 `{ cancel }`。GET 的 `cache_ttl>0` 走 `http` 表；业务层（含 `online/`）不自己判新鲜度。

## 用法

```lua
local Request = require("http.request")

local h = Request.get(url, {
    headers = { Authorization = "…" },
    cache_ttl = 3600,
    timeout = 20,
}, function(res, err)
    if not Request.ok(res and res.code) then return end
    local body = res.body
end)

Request.post(url, body, { headers = … }, cb)
Request.download({ url = url }, dest_path, cb)
Request.stream({ url = url }, {
    on_headers = function(res) end,
    on_chunk = function(chunk) end,
    on_done = function(res, err) end,
})

h.cancel()
Request.clearCache("example.com")  -- 可选 substr
```

日志里的 URL 会剥 query/fragment/userinfo，别往日志塞带令牌的完整 URL。
