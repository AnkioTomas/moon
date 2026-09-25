# workers/ — Job

路径：[`book.koplugin/workers/`](../../book.koplugin/workers/)。

## 设计

`Job.run` 发一次性任务。`instant` 主线程 `nextTick`（可碰 SQLite）；其余 fork，结果回主进程再写库。子进程里 `Job.inSubProcess()` 为真，`db.base` 拒库。

| kind | 怎么跑 | 收结果间隔 | 典型用途 |
|---|---|---|---|
| `instant` | 不 fork | 下一帧（闭包宜 <~200ms） | 写库、轻量主线程 |
| `light` | fork | 0.5s | marks、单文件解析 |
| `medium` | fork | 2s | 扫盘 |
| `heavy` | fork | 5s | 下载打包、装字典 |

并发：`System:concurrency()` ≈ 可用内存/32MB，夹在 1～20。

## 用法

```lua
local Job = require("workers.job")

local job = Job.run(function()
    -- fork 闭包：禁止捕获 UI / SQLite / socket / userdata
    -- 返回值必须是 JSON 可编码的 table
    return { files = 10 }
end, {
    name = "local.scan",
    kind = "medium",
    on_done = function(result) end,
    on_failed = function(err) end,
    on_cancelled = function() end,
    timeout = 30,
})

job:cancel()
```

UI 组件里登记到 Lifecycle：`lifecycle:addHttp(job)`（接受任何带 `cancel` 方法的句柄），Pause / Destroy 时自动取消。
