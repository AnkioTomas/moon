
# Workers

这里是独立于 `utils/task.lua` 的长期双向 Worker 基础设施。

```lua
local Worker = require("workers.master").new {
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

`Master:waitEvent` 可直接交给 `UIManager:insertZMQ`；它只做非阻塞 pipe 读写、协议解析和回调。
子进程退出后，已发送请求失败回调，尚未发送的请求保留，并按退避时间自动重新拉起子进程。

当前模块不负责数据库或文件业务，也不允许 handler 触碰主进程 UI、SQLite 连接、文件 userdata 或 socket userdata。
