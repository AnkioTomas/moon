# remote.server — HTTP 核心

代码：[`remote/server.lua`](../../book.koplugin/remote/server.lua)。

## 设计

纯 LuaSocket 增量状态机：读请求 → 调注入的 handler → 写响应。  
经 `UIManager:insertZMQ` 驱动，单次 waitEvent 时间片很短（默认约 25ms），避免堵 UI。

- 最大连接数有上限（如 `MAX_CONNS=32`）
- 不解析 multipart；上传 body 由 file 路由处理落盘
- 认证/端口等来自 settings，经 init 注入

路由在 `server.lua` 加载时挂到 `Server` 上（init 只注入 handlers）：文件侧 `_routeList` / `_routeDownload` / `_routeUpload` / `_routeMutate` / `_routeRename` / `_routeExtract`，以及 `_routeInput`、`_routeClipboard`、`_routeStatus`、`_routeSettings`、静态资源等。

---

## 用法

一般**不要**直接 new server；走 `require("remote").start()`。

测试或嵌入时：

```lua
local Server = require("remote.server")
local srv = Server.new({
    port = 8080,
    root = "/mnt/onboard",  -- 必填
    handlers = { … },       -- 必填：目录列表、读文件、写文件、mkdir、rename、删除…
})
srv:start()
-- 由 UIManager insertZMQ 泵事件
srv:stop()
```

新增 API：

1. 在 `file.lua` / `input.lua` / 新模块写路由函数（首参即 server 实例 self）
2. 在 `server.lua` 顶部 `Server._routeXxx = M.fn` 挂上，并在 `Server:_route` 里分派
3. 前端静态页或 `/api/…` 调用
4. 权限：路径必须落在受管根内（init 的 containment 检查）

### 注意

- server 核心禁止 require Widget / NetworkMgr。
- 路径检查必须用 realpath 后的前缀，软链不能当逃逸口。
- 改端口时先记旧 `_punched_port`，停服拆旧规则再打新孔。
