# Workers

只有 `Job`。`kind` 决定堵不堵 UI，以及隔多久看一眼结果。

| kind | 怎么跑 | 何时收结果 |
| --- | --- | --- |
| `instant` | 不 fork，`nextTick` | 下一帧。闭包应在约 200ms 内结束 |
| `light` | fork | 0.5s |
| `medium` | fork | 2s |
| `heavy` | fork | 5s |

库操作只能 `instant`。fork 子进程里 `Job.inSubProcess()` 为真，`db.base` 据此拒库。下载、打包、装字典用 `heavy`；marks、单文件解析用 `light`；扫盘用 `medium`。

```lua
local Job = require("workers.job")

local job = Job.run(function()
    return { files = 10 }
end, {
    name = "local.scan",
    kind = "medium",
    on_done = function(result) end,
    on_failed = function(err) end,
    on_cancelled = function() end,
    timeout = 30,
})

job:cancel() -- abort 是同义词
```

fork 闭包在子进程继承，返回值必须是 JSON 可编码的 table。不要捕获 UI、SQLite、socket、userdata。父进程不挂 ZMQ。
