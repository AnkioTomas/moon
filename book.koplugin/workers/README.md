# Workers

`book.koplugin/workers` 只提供两种任务模型：一次性子进程 `Job`，以及主线程下一帧执行的 `SimpleJob`。目录内没有常驻进程管理器，也没有数据库专用 worker。

## 目录模块

| 模块 | 作用 | 典型调用方 |
| --- | --- | --- |
| `workers/job` | fork 一次性子进程，传输进度和最终结果 | 文件扫描、转换、校验等重任务 |
| `workers/simple_job` | 使用 `UIManager:nextTick` 延后执行闭包 | 很短的主线程任务、拆分 UI 工作 |
| `workers/context` | Job 子进程上下文，发送进度 | 仅由 `workers/job` 注入的 `ctx` 使用 |
| `workers/protocol` | IPC 帧编码、增量解码和 EOF 校验 | Job 内部协议层，一般不直接调用 |

## Job

```lua
local Job = require("workers/job")

local job = Job.run(function(ctx)
    for i = 1, 10 do
        ctx.post({ phase = "scan", current = i, total = 10 })
    end
    return { files = 10 }
end, {
    on_progress = function(progress, job) end,
    on_done = function(result) end,
    on_failed = function(err) end,
    on_state = function(state, job) end,
})

job:cancel()
```

`Job.run` 会 fork 子进程；闭包在 fork 时继承，不经过 IPC 序列化。`ctx.post` 的参数、任务返回值和进度数据必须是 JSON 可编码的 Lua table。不要捕获 UI、SQLite、socket 或文件 userdata。任务结束后子进程退出。

Job 状态为 `queued`、`running`、`done`、`failed` 或 `cancelled`。`job:status()` 返回当前状态；`Job.get(id)`、`Job.list()` 查询活动任务，`Job.stop()` 取消全部活动任务。`timeout` 可在选项中指定超时秒数。

## SimpleJob

```lua
local SimpleJob = require("workers/simple_job")

local task = SimpleJob.nextTick(function()
    return update_small_piece()
end, {
    on_done = function(result) end,
    on_failed = function(err) end,
})

task:cancel()
```

`SimpleJob.run` 与 `SimpleJob.nextTick` 等价。任务只排入 `UIManager:nextTick`，不 fork、不建 pipe；取消只能阻止尚未开始的回调，不能中断已经运行的同步闭包。状态和 `task:status()` 与 Job 类似。

## IPC 协议

`workers/protocol` 使用字节流帧：8 个 ASCII 十六进制字符表示 payload 长度，后跟 JSON payload。

```lua
local Protocol = require("workers/protocol")

local frame = Protocol.encode({ type = "progress", value = { current = 1 } })
local decoder = Protocol.newDecoder()
local messages, err = Protocol.feed(decoder, frame:sub(1, 4))
messages, err = Protocol.feed(decoder, frame:sub(5))
local complete, finish_err = Protocol.finish(decoder)
```

`Protocol.feed` 支持半包和一次输入多个完整帧；任何非法长度、非法 JSON 或超过 `MAX_FRAME` 的帧都会返回错误。子进程 EOF 时必须调用 `Protocol.finish`，残留字节表示不完整帧。

`workers/context` 的 `enter`、`leave` 由 Job 内部管理；业务闭包只使用传入的 `ctx.post(message)`。在 Job 外调用 `Context.post` 会抛出错误。
