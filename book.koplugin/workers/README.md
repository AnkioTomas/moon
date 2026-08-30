# Workers

这里是独立于 `utils/task.lua` 的后台执行基础设施。DB 是常驻双向 Worker；Job 在提交时 fork，因此可执行现有 Lua 闭包并向主线程回报状态。

```lua
local Worker = require("workers.runtime").new {
    handlers = {
        ping = function(args)
            return { value = args.value }
        end,
    },
}

Worker:attach()
Worker:request("ping", { value = 1 }, function(result, err)
    -- 回调始终在主进程
end)
```

子进程只接收 JSON 可编码的 table，handler 由主进程在创建时提供并在子进程内执行。
请求通过双向匿名 pipe 传输，协议为 8 位十六进制长度头加 JSON payload。

`Runtime:waitEvent` 可直接交给 `UIManager:insertZMQ`；它只做非阻塞 pipe 读写、协议解析和回调。
子进程退出后，已发送请求失败回调，尚未发送的请求保留，并按退避时间自动重新拉起子进程。

当前模块不负责数据库或文件业务，也不允许 handler 触碰主进程 UI、SQLite 连接、文件 userdata 或 socket userdata。

## DB 常驻执行域

```lua
local Workers = require("workers/init")
local DB = Workers.get("db")

Workers.attach()
DB:request("query", {
    sql = "SELECT * FROM books WHERE source_id = ? LIMIT ?;",
    params = { "local", 24 },
}, cb)
```

`DB` 在子进程启动时先丢弃 fork 继承的 SQLite 状态，再由首次请求重新打开连接。只提供参数化 `query`/`exec`，不增加一层伪 ORM。它会保持运行，直到 `Workers.destroy("db")` 或 KOReader 退出；异常退出则自动按退避重启。

## 通用 Job

```lua
local Workers = require("workers/init")

local job = Workers.run(function(ctx)
    ctx:post({ phase = "scan", current = 1, total = 10 })
    return { files = 10 }
end, {
    on_progress = function(progress, job)
        -- 主线程：job:status() 可读 state/progress/error
    end,
    on_done = function(result) end,
    on_failed = function(err) end,
})

job:cancel()
```

闭包在 fork 时继承到子进程，不会通过 IPC 序列化。`ctx:post` 与返回值必须是 JSON 可编码数据；不要捕获 SQLite、UI、socket 或文件 userdata。Job 完成后自然退出；`Workers.Job.list()` 可取得仍在运行的任务状态。

新增常驻执行域只需要注册一个定义，不需要复制 pipe、重启或事件循环代码：

```lua
Workers.define("search", {
    handlers = { ping = function() return { alive = true } end },
})
```

网络仍由主进程 Turbo 事件循环处理。
