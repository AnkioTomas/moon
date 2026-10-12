# workers

后台执行的两层设施，互不依赖，按需要选一个：

| 模块 | 解决什么 | 典型调用方 |
|---|---|---|
| `job.lua` | 一段计算放到 fork 子进程（或下一 tick）跑，不卡 UI | 解析、转换、扫盘、解压校验 |
| `tasks.lua` | 用户发起、耗时长的操作排队、去重、重试、展示进度 | 书城下载、字典 / 词库下载、全本缓存、书架同步 |

一句话区分：**Job 管"在哪跑"，Tasks 管"谁先跑、跑没跑完、用户看不看得到"。**
一个 Task 的 `run` 里可以起若干 Job，也可以只发 HTTP；Tasks 不关心。

```text
workers/
├── job.lua          -- 一次性任务：instant / fork，返回 Job，可 cancel
├── system.lua       -- fork 调度：全局 FIFO，按可用内存限并发
├── protocol.lua     -- 子进程 → 父进程管道帧：8 位十六进制长度 + JSON
├── tasks.lua        -- 后台任务队列（零 UI）
└── ui/
    └── task_dialog.lua  -- 任务列表弹窗 + 前台进度弹窗 + 顶栏共用文案
```

## Job

```lua
local Job = require("workers.job")

local job = Job.run(function(progress)
    -- 子进程里：只做 FS / 解析，禁止碰 sqlite
    progress(0.5)
    return { ok = true, count = 42 }     -- 返回值经 JSON 回传，必须可序列化
end, {
    name = "scan_books",                 -- 必填，日志用
    kind = "medium",                     -- instant | light | medium | heavy
    timeout = 60,                        -- 可省；仅 fork 任务生效
    on_done = function(result) end,
    on_failed = function(err) end,
    on_cancelled = function(job) end,
    on_progress = function(value) end,
})

job:cancel()
```

| kind | 是否 fork | 父进程轮询间隔 |
|---|---|---|
| `instant` | 否，`UIManager:nextTick` 里跑 | — |
| `light` | 是 | 0.5s |
| `medium` | 是 | 2s |
| `heavy` | 是 | 5s |

必须知道的行为：

- **子进程禁止碰 sqlite。** 库连接不能跨 fork。要读写库就用 `instant`，或者子进程只产出数据，回调里在主进程落库。
- **`instant` 会卡 UI。** 闭包应在约 200ms 内结束；超过这个量级就该 fork。
- **结果走 JSON。** 函数、userdata、循环引用都传不回来；单帧上限 4MB（`Protocol.MAX_FRAME`）。
- **progress 每调一次写一帧。** 管道有容量上限，调用方自己节流，别每行调一次。
- **回调恰好一个。** `on_done` / `on_failed` / `on_cancelled` 三选一，只触发一次；回调抛错记日志但不影响槽位释放。
- **排队中也能取消。** 还没拿到槽位的 fork 任务 `cancel` 直接结束，不会再被拉起。
- **子进程判断：** `Job.inSubProcess()`，在子进程里为 true，用于拦截误入子进程的库操作等。
- **句柄挂在拥有者实例上。** 模块级 `_job` 变量视为缺陷；取消只杀自己那一条。

### system / protocol

`Job.run` 只把 fork 任务交给 `system.lua`，由它 FIFO 排队并按并发上限拉起：
每 32MB `MemAvailable` 一个槽，夹在 1～20，读不到 `/proc/meminfo` 按 4。`instant` 不进调度。

`protocol.lua` 是管道的分帧编解码，处理半包拼接。业务代码不直接用这两个模块。

## Tasks

面向用户的后台任务队列。只放用户发起、耗时长、不该挡界面的操作。
关书推进度 / 笔记 / 统计、脏重试、自动书架同步这类静默小请求**不入队**；开书下载（用户正等着读）保持模态。

```lua
local task, reason = require("workers.tasks").enqueue{
    key = "cache\0wechat\0123",          -- 必填且唯一
    kind = "cache",                      -- download | sync | cache
    title = "书名",
    restartable = true,                  -- 可省；见下文
    run = function(report, done)
        report(text, count, total)       -- 三者皆可省；download 类 count/total 是字节数
        done({ ok = true })              -- 每次尝试恰好调一次
        return handle                    -- { cancel = fun() }，可省
    end,
    retryable = function(result) return true end,  -- 可省；真则退避重试
    on_done = function(result) end,      -- 可省；最终结束调一次，取消不调
}
-- 被拒时 task 为 nil，reason = "running" | "queue_full"
task.cancel()
```

需要前台进度窗的，直接用 `workers/ui/task_dialog`：

```lua
require("workers.ui.task_dialog").start{ key = …, kind = …, title = …, run = … }  -- 入队 + 跟随 + 被拒提示
require("workers.ui.task_dialog").follow(task)                                   -- 已自行入队的任务
```

### run 跑在主进程

`Tasks` 不 fork。`start` 在主进程直接调用 `task.run`，`run` 必须**发起异步操作后立刻返回**，否则整个界面冻住：

- 等网络：走 `http/request`（Turbo 非阻塞，经 `UIManager:insertZMQ` 每圈泵一拍，poll 超时 0），不占主线程。
- 重计算（校验、拼接、解压、打包、解析大文件）：走 `Job` fork 子进程。
- 回调里只做轻活：写单个小文件、单条写库、上报进度。

队列不检查这一点，写任务的人自己保证。

### 组合：下载 + 重计算

最常见的形态是"先下载，再校验解压"。下载在主进程非阻塞跑，下完换 `Job` 进子进程算，
`run` 返回的句柄要始终指向**当前阶段**，取消 / 休眠中断才能真正停下正在跑的那一步：

```lua
require("workers.ui.task_dialog").start{
    key = "pack\0" .. id,
    kind = "download",
    title = name,
    restartable = true,
    run = function(report, done)
        local current                                   -- 当前阶段句柄：先下载，后 Job
        current = Request.download({
            url = url,
            timeout = 300,
            on_progress = function(written, total) report(_("正在下载…"), written, total) end,
        }, tmp, function(ok, err)
            if not ok then return done({ ok = false, err = err }) end
            current = Job.run(function(progress)        -- 子进程：只碰文件，禁止碰 sqlite
                verifyAndExtract(tmp, dest, progress)
            end, {
                name = "pack.extract",
                kind = "heavy",
                timeout = 300,
                on_progress = function(bytes) report(_("正在解压…"), bytes, size) end,
                on_done = function()                    -- 回到主进程：写库、重置连接在这里
                    done({ ok = true })
                end,
                on_failed = function(e) done({ ok = false, err = e }) end,
            })
        end)
        return { cancel = function() current:cancel() end }
    end,
}
```

要点：

- **句柄跟着阶段换。** 只返回下载句柄的话，进入解压阶段后取消就只改了队列状态，子进程继续跑成孤儿。
- **取消后不会再回调。** `Request.download` 取消后不调 `cb`；`Job` 取消后只触发 `on_cancelled`、并杀掉子进程。
  即使有迟到的 `done`，队列也按 token 丢弃，不用自己加 cancelled 标记。
- **子进程只做 FS / 解析。** 结果（或落盘路径）回主进程，写库、`reset` 连接、改设置都放在 `on_done`。
- **restartable 会从头重跑 `run`。** 断点续传靠落盘状态：已完整的分片按大小 / 校验跳过，解压写临时目录、成功后原子改名。
  不要用模块级 `_downloading` 之类的标记去重，队列的 key 已经做了。
- **kind 选 `heavy` 还是 `medium`。** 看进度条要不要动：`heavy` 5s 收一次管道，需要平滑进度用 `medium`（2s）。

### 进度与百分比

任务只报 `report(text, count, total)`，百分比由界面算：`total > 0` 时进度窗和任务列表按 `count / total` 画进度条，
`total` 为 0 / 省略时进度条不动。说明行**不显示 `%`**，而是：

| kind | 说明行 |
|---|---|
| `download` | `text` + `x.x / y.y MB`（count / total 当字节数） |
| `sync` / `cache` | `text` + `count/total` |

要点：

- **download 类所有阶段都报字节。** 解压阶段按文件数报 `report(t, 3, 120)` 会显示成 `0.0 / 0.0 MB`；
  拿不到字节就换算成字节（如已解压的原始大小），或只给 `text`、不给 count / total。
- **省略的参数沿用上次值。** `count` / `total` 传 nil 不清零，`text` 传 nil 会清掉文案。
- **阶段切换进度条会回到 0。** 要一条走到底的总进度，自己把各阶段折算到同一个 `total`
  （如下载 `written`、解压 `size_zip + extracted`，`total = size_zip + size_raw`）。
- **没有 `Content-Length` 就没有 `total`。** 清单里有大小（分片 manifest）就用清单的，不要依赖响应头。
- **子进程的 `progress` 自己节流。** 每调一次写一帧管道，按字节数或时间间隔报，不要每个块都报。

现有同形态实现：`features/dictionary/manager.lua`（分片下载 → `heavy` 解压安装）、
`features/ime/download.lua`（分片下载 → `medium` 拼接校验）。

### 调度规则

- **同类并行，异类互斥。** 有任务在跑（或退避占位）时只放行同类；队首是异类时后面的同类不插队，免得异类饿死。
- **key 去重。** 同 key 旧任务还在排队就被替换（按取消处理，不调 `on_done`）；已在执行则拒绝新任务，返回 `"running"`。
- **上限 64 个未结束任务**，超出返回 `"queue_full"`。
- **重试。** `retryable(result)` 为真时退避重试，间隔 15s、30s…，最多 3 次尝试；退避期间继续占执行权。
- **不持久化。** 任务只活在本进程，断点靠业务自己的落盘状态（已缓存章节、脏标记）。
- **队列零 UI。** 进度文案、完成提示、可否重试都由任务自己给。`Tasks.watch(cb)` 只供 UI 订阅刷新，返回的 `cancel` 只注销观察者。

### restartable

`restartable` 的任务归队列所有，队列可以随时中断并从头重跑它，所以 `run` 必须可重入、能从落盘状态续上：

- 休眠（`main.lua` `onSuspend` → `Tasks.onSuspend`）：中断在跑的任务，放回 `waiting`，唤醒前不再启动。
- 断网失败（`result.ok` 为假且 `NetworkMgr:isConnected()` 为假）：放回 `waiting`，不算失败、不消耗重试次数。
  用 `isConnected` 而不是 `isOnline`，后者会阻塞在 DNS 上。
- 唤醒 / 联网（`Tasks.onResume` / `Tasks.onNetworkConnected`）：`waiting` 按原顺序续跑。
- 用户只能取消 restartable 任务。书架同步归桌面所有，不设 restartable，队列只展示。

### 状态

`queued` → `running` → `finished`，旁路 `retry_wait`（退避）、`waiting`（等唤醒 / 网络）、`cancelled`。
`Tasks.tasks()` 返回快照副本，顺序为运行 / 退避中 → 等网络 → 排队，同组按入队顺序；`Tasks.get(key)` 取未结束任务。
`Tasks.finished()` 返回最近结束的 10 条快照（新的在前，同 key 只留最新，取消的不记；`ok` 表示成功），只供任务列表展示。

## 测试

`tests/workers/` 与本目录镜像：`job_spec` / `system_spec` / `protocol_spec` / `tasks_spec` / `ui/task_dialog_spec`。

```sh
./tests/run.sh tests/workers
```
