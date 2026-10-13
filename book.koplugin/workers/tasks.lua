--[[--
后台任务队列：用户发起、耗时长的操作，按 kind 分四类：
`download` 资源下载（书城、字典、输入法词库）、`sync` 书库同步、`cache` 书籍缓存、
`online` ankio.net 公共接口（天气 / 一言 / 摸鱼日报 / 必应；自动入队，不弹进度窗）。

同类可以并行，异类互斥：有任务在跑（或退避占位）时只放行同类；队首排队的是异类时后面的同类不插队，
免得异类饿死。key 必填且唯一：同 key 还在排队的旧任务被新任务替换（旧的按取消处理），已在执行的拒绝新任务。
任务只活在本进程；断点靠各业务自己的落盘状态（已缓存章节、脏标记），不持久化队列。
队列不认识业务：进度文案、完成提示、可否重试都由任务自己给；download 类的 count/total 是字节数。
前台弹窗 / 转后台 / 被拒提示由 `workers/ui/task_dialog`（`start` / `follow`）负责，队列本身零 UI。

restartable 的任务归队列所有，队列可以随时中断并从头重跑它：
休眠（`Tasks.onSuspend`）时中断、放回 waiting；断网导致的失败（result.ok 为假且设备未连网）
也放回 waiting，不算失败、不消耗重试次数；`Tasks.onResume` / `Tasks.onNetworkConnected` 后按原顺序续跑。
用户也只能取消 restartable 的任务（`cancelable = false` 的除外）。书架同步归桌面所有，不设 restartable，队列只展示。

  local task, reason = Tasks.enqueue{       -- 被拒时 task 为 nil，reason = running / queue_full
      key = "cache\0wechat\0123", kind = "cache", title = "书名",
      restartable = true,
      run = function(report, done)          -- 返回 { cancel } 句柄
          report(text, count, total)         -- 三者皆可省
          done(result)                       -- 每次尝试恰好一次；result.ok 表示成功
      end,
      retryable = function(result) end,     -- 可省；真则退避重试（最多 3 次）
      on_done = function(result) end,       -- 可省；最终结束时调一次，取消不调
  }
  task.cancel()

@module koplugin.book.workers.tasks
--]]

local Guard = require("ui.guard")

local Tasks = {}

---@alias BookTaskKind "download"|"sync"|"cache"|"online"

---@class BookTask
---@field key string
---@field kind BookTaskKind
---@field title string|nil
---@field restartable boolean|nil
---@field cancelable boolean|nil false：restartable 也不给用户取消（进度窗与任务列表都不出取消）
---@field run fun(report: fun(text: string|nil, count: integer|nil, total: integer|nil), done: fun(result: table)): table|nil
---@field retryable (fun(result: table): boolean)|nil
---@field on_done fun(result: table)|nil
---@field state "queued"|"running"|"retry_wait"|"waiting"|"finished"|"cancelled"|nil
---@field done boolean|nil
---@field result table|nil
---@field attempt integer|nil
---@field text string|nil
---@field count integer|nil
---@field total integer|nil
---@field cancel fun()|nil
---@field handle { cancel: fun() }|nil
---@field token any|nil
---@field retry_tick fun()|nil
---@field _online_url string|nil

local MAX_ATTEMPTS = 3
local RETRY_DELAY_SECONDS = 15
local MAX_PENDING = 64
local MAX_FINISHED = 10
local KINDS = { download = true, sync = true, cache = true, online = true }

---@type BookTask[] 未结束任务，入队顺序
local list = {}
--- 最近结束（非取消）的任务快照，新的在前；同 key 只留最新一条。
local finished = {}
---@type table<string, BookTask>
local by_key = {}
local watchers = {}
local change_scheduled = false
--- 休眠中：restartable 任务不启动。
local suspended = false

--- 通知观察者；订阅者只是 UI，绝不拥有或取消任务。
local function flushChanged()
    change_scheduled = false
    for callback in pairs(watchers) do
        Guard.call("tasks watcher", callback)
    end
end

local function changed()
    if change_scheduled then return end
    change_scheduled = true
    require("ui/uimanager"):scheduleIn(0.25, flushChanged)
end

---@param task BookTask
local function remove(task)
    for i, item in ipairs(list) do
        if item == task then
            table.remove(list, i)
            break
        end
    end
    by_key[task.key] = nil
end

---@param task BookTask
---@return table
local function snapshot(task)
    return {
        key = task.key,
        kind = task.kind,
        title = task.title,
        state = task.state,
        text = task.text,
        count = task.count,
        total = task.total,
        attempt = task.attempt,
        restartable = task.restartable == true,
        cancelable = task.cancelable,
        ok = task.result and task.result.ok == true,
    }
end

---@param task BookTask
local function archive(task)
    for i = #finished, 1, -1 do
        if finished[i].key == task.key then table.remove(finished, i) end
    end
    table.insert(finished, 1, snapshot(task))
    finished[MAX_FINISHED + 1] = nil
end

--- 占着执行权的类型：有 running / retry_wait 任务时为其类型。
---@return BookTaskKind|nil
local function activeKind()
    for _idx, task in ipairs(list) do
        if task.state == "running" or task.state == "retry_wait" then return task.kind end
    end
end

--- 下一个可启动的排队任务；队首可启动的排队任务是异类时返回 nil（后面的同类不插队）。
---@return BookTask|nil
local function nextQueued()
    local kind = activeKind()
    for _idx, task in ipairs(list) do
        if task.state == "queued" and not (suspended and task.restartable) then
            if kind == nil or task.kind == kind then return task end
            return nil
        end
    end
end

local start

local function startNext()
    local task = nextQueued()
    while task do
        start(task)
        task = nextQueued()
    end
end

--- 中断当前尝试、放回 waiting；这次尝试不计入重试次数。
---@param task BookTask
local function park(task)
    local handle = task.handle
    task.handle = nil
    task.token = nil
    if task.state == "running" then task.attempt = task.attempt - 1 end
    task.state = "waiting"
    if handle then handle:cancel() end
end

---@param task BookTask
---@param result table
local function settle(task, result)
    task.handle = nil
    if task.restartable and not result.ok
        and not require("ui/network/manager"):isConnected() then
        park(task)
        changed()
        startNext()
        return
    end
    if task.retryable and task.attempt < MAX_ATTEMPTS and task.retryable(result) then
        -- 退避期间继续占执行权，避免异类任务趁窗口开跑。
        task.state = "retry_wait"
        task.retry_tick = function()
            task.retry_tick = nil
            task.state = "queued"
            changed()
            startNext()
        end
        require("ui/uimanager"):scheduleIn(RETRY_DELAY_SECONDS * (2 ^ (task.attempt - 1)), task.retry_tick)
        changed()
        return
    end
    task.state = "finished"
    task.done = true
    task.result = result
    remove(task)
    archive(task)
    if task.on_done then Guard.call("task on_done " .. task.kind, task.on_done, result) end
    changed()
    startNext()
end

---@param task BookTask
start = function(task)
    task.state = "running"
    task.attempt = task.attempt + 1
    local token = {}
    task.token = token
    local function live()
        return task.token == token and task.state == "running"
    end
    changed()
    -- run 同步抛错时任务还停在 running，会永远占着执行权；按失败结算后队列继续。
    local ran, handle = Guard.call("task run " .. task.kind, function()
        return true, task.run(function(text, count, total)
            if not live() then return end
            task.text = text
            task.count = count or task.count
            task.total = total or task.total
            changed()
        end, function(result)
            if live() then settle(task, result) end
        end)
    end)
    if not ran then
        if live() then settle(task, { ok = false, err = "task crashed" }) end
        return
    end
    if live() then task.handle = handle end
end

---@param task BookTask
local function cancel(task)
    if task.done then return end
    task.done = true
    task.state = "cancelled"
    if task.retry_tick then
        require("ui/uimanager"):unschedule(task.retry_tick)
        task.retry_tick = nil
    end
    local handle = task.handle
    task.handle = nil
    remove(task)
    if handle then handle:cancel() end
    changed()
    startNext()
end

--- 入队。key 必填且唯一：同 key 旧任务还在排队（queued）就踢掉它（按取消处理，不调 on_done），
--- 新任务排到队尾；旧任务已在执行（running / retry_wait / waiting）则拒绝。
---@param spec BookTask 见模块头；表本身即任务对象
---@return BookTask|nil task 入队的任务；被拒时为 nil
---@return "running"|"queue_full"|nil reason 被拒原因
function Tasks.enqueue(spec)
    assert(KINDS[spec.kind], "unknown task kind")
    assert(type(spec.key) == "string" and spec.key ~= "", "task key required")
    local existing = by_key[spec.key]
    if existing then
        if existing.state ~= "queued" then return nil, "running" end
        cancel(existing)
    end
    -- 同类并行时在跑的也会无限增长，上限按全部未结束任务算。
    if #list >= MAX_PENDING then return nil, "queue_full" end
    local task = spec
    task.state = "queued"
    task.done = false
    task.attempt = 0
    task.count = 0
    task.total = 0
    task.cancel = function() cancel(task) end
    by_key[task.key] = task
    list[#list + 1] = task
    changed()
    startNext()
    return task
end

--- 休眠前：中断在跑的 restartable 任务放回 waiting，唤醒前不再启动它们。
--- 退避中的任务不动：定时器唤醒后才会到点。
function Tasks.onSuspend()
    suspended = true
    for _idx, task in ipairs(list) do
        if task.restartable and task.state == "running" then
            park(task)
            changed()
        end
    end
end

--- 唤醒：waiting 放回队列按原顺序续跑。仍未联网时会再次失败回到 waiting，代价是一次立即失败的请求。
function Tasks.onResume()
    suspended = false
    for _idx, task in ipairs(list) do
        if task.state == "waiting" then
            task.state = "queued"
            changed()
        end
    end
    startNext()
end

--- 联网：与唤醒相同，放行等网络的任务。
Tasks.onNetworkConnected = Tasks.onResume

--- 按 key 取未结束的任务。
---@param key string
---@return BookTask|nil
function Tasks.get(key)
    return by_key[key]
end

local ORDER = { running = 1, retry_wait = 1, waiting = 2, queued = 3 }

--- 任务快照：运行 / 退避中的在前，其次等待网络的，最后排队的；同组按入队顺序。返回副本。
---@return { key: string, kind: BookTaskKind, title: string|nil, state: string, text: string|nil, count: integer, total: integer, attempt: integer, restartable: boolean, cancelable: boolean|nil }[]
function Tasks.tasks()
    local out = {}
    for group = 1, 3 do
        for _idx, task in ipairs(list) do
            if ORDER[task.state] == group then out[#out + 1] = snapshot(task) end
        end
    end
    return out
end

--- 最近结束的任务（最多 10 条，新的在前，取消的不算）；state 为 finished，ok 表示成功。返回副本。
---@return table[]
function Tasks.finished()
    return { unpack(finished) }
end

--- 订阅状态改变。返回的 cancel 只注销观察者，绝不影响任务。
---@param callback fun()
---@return { cancel: fun() }
function Tasks.watch(callback)
    watchers[callback] = true
    return { cancel = function() watchers[callback] = nil end }
end

return Tasks
