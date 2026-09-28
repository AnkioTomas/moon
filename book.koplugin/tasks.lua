--[[--
后台任务队列：用户发起、耗时长、不该挡住界面的操作（全本缓存、书城下载、书架同步）。

同一 lane 内串行，不同 lane 互不等待；key 去重，重复入队返回在跑的那条。
任务只活在本进程；断点靠各业务自己的落盘状态（已缓存章节、脏标记），不持久化队列。
队列不认识业务：进度文案、完成提示、可否重试都由任务自己给。

restartable 的任务归队列所有，队列可以随时中断并从头重跑它：
休眠（`Tasks.suspend`）时中断、放回 waiting；断网导致的失败（result.ok 为假且设备未连网）
也放回 waiting，不算失败、不消耗重试次数；`Tasks.wake`（唤醒 / 联网）后按原顺序续跑。
用户也只能取消 restartable 的任务。书架同步归桌面所有，不设 restartable，队列只展示。

  local task, queued, reason = Tasks.enqueue{
      key = "cache\0wechat\0123", lane = "cache", label = _("缓存"), title = "书名",
      restartable = true,
      run = function(report, done)          -- 返回 { cancel } 句柄
          report(text, count, total)         -- 三者皆可省
          done(result)                       -- 每次尝试恰好一次；result.ok 表示成功
      end,
      retryable = function(result) end,     -- 可省；真则退避重试（最多 3 次）
      on_done = function(result) end,       -- 可省；最终结束时调一次，取消不调
  }
  task.cancel()

@module koplugin.book.tasks
--]]

local Tasks = {}

---@class BookTask
---@field key string
---@field lane string
---@field label string
---@field title string|nil
---@field restartable boolean|nil
---@field run fun(report: fun(text: string|nil, count: integer|nil, total: integer|nil), done: fun(result: table)): table|nil
---@field retryable fun(result: table): boolean|nil
---@field on_done fun(result: table)|nil
---@field state "queued"|"running"|"retry_wait"|"waiting"|"finished"|"cancelled"
---@field done boolean
---@field result table|nil
---@field attempt integer
---@field text string|nil
---@field count integer
---@field total integer
---@field cancel fun()

local MAX_ATTEMPTS = 3
local RETRY_DELAY_SECONDS = 15
local MAX_PENDING = 64

---@type BookTask[] 未结束任务，入队顺序
local list = {}
---@type table<string, BookTask>
local by_key = {}
---@type table<string, BookTask> lane → 占槽任务（running / retry_wait）
local busy = {}
local watchers = {}
local change_scheduled = false
--- 休眠中：restartable 任务不启动。
local suspended = false

--- 通知观察者；订阅者只是 UI，绝不拥有或取消任务。
local function flushChanged()
    change_scheduled = false
    for callback in pairs(watchers) do
        callback()
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
    if busy[task.lane] == task then busy[task.lane] = nil end
end

---@return BookTask|nil
local function nextQueued()
    for _, task in ipairs(list) do
        if task.state == "queued" and not busy[task.lane]
            and not (suspended and task.restartable) then
            return task
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
    if busy[task.lane] == task then busy[task.lane] = nil end
    if handle and handle.cancel then handle:cancel() end
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
        -- 退避期间继续占 lane，避免排在后面的任务趁窗口开跑。
        task.state = "retry_wait"
        task.retry_tick = function()
            task.retry_tick = nil
            task.state = "queued"
            busy[task.lane] = nil
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
    if task.on_done then task.on_done(result) end
    changed()
    startNext()
end

---@param task BookTask
start = function(task)
    busy[task.lane] = task
    task.state = "running"
    task.attempt = task.attempt + 1
    local token = {}
    task.token = token
    local function live()
        return task.token == token and task.state == "running"
    end
    changed()
    local handle = task.run(function(text, count, total)
        if not live() then return end
        task.text = text
        task.count = tonumber(count) or task.count
        task.total = tonumber(total) or task.total
        changed()
    end, function(result)
        if live() then settle(task, result or {}) end
    end)
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
    if handle and handle.cancel then handle:cancel() end
    changed()
    startNext()
end

--- 入队。同 key 已在排队或运行时复用既有任务。
---@param spec table 见模块头；表本身即任务对象
---@return BookTask|nil task
---@return boolean queued 是否新入队
---@return string|nil reason 入队失败原因（目前只有 queue_full）
function Tasks.enqueue(spec)
    local existing = by_key[spec.key]
    if existing then return existing, false end
    local queued = 0
    for _, task in ipairs(list) do
        if task.state == "queued" or task.state == "waiting" then queued = queued + 1 end
    end
    if queued >= MAX_PENDING then return nil, false, "queue_full" end
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
    return task, true
end

--- 休眠前：中断在跑的 restartable 任务放回 waiting，唤醒前不再启动它们。
--- 退避中的任务不动：定时器唤醒后才会到点。
function Tasks.suspend()
    suspended = true
    for _, task in ipairs(list) do
        if task.restartable and task.state == "running" then
            park(task)
            changed()
        end
    end
end

--- 唤醒 / 联网：waiting 放回队列按原顺序续跑。仍未联网时会再次失败回到 waiting，代价是一次立即失败的请求。
function Tasks.wake()
    suspended = false
    for _, task in ipairs(list) do
        if task.state == "waiting" then
            task.state = "queued"
            changed()
        end
    end
    startNext()
end

--- 按 key 取未结束的任务。
---@param key string
---@return BookTask|nil
function Tasks.get(key)
    return by_key[key]
end

local ORDER = { running = 1, retry_wait = 1, waiting = 2, queued = 3 }

--- 任务快照：运行 / 退避中的在前，其次等待网络的，最后排队的；同组按入队顺序。返回副本。
---@return { key: string, lane: string, label: string, title: string|nil, state: string, text: string|nil, count: integer, total: integer, attempt: integer, restartable: boolean }[]
function Tasks.tasks()
    local out = {}
    for group = 1, 3 do
        for _, task in ipairs(list) do
            if ORDER[task.state] == group then
                out[#out + 1] = {
                    key = task.key,
                    lane = task.lane,
                    label = task.label,
                    title = task.title,
                    state = task.state,
                    text = task.text,
                    count = task.count,
                    total = task.total,
                    attempt = task.attempt,
                    restartable = task.restartable == true,
                }
            end
        end
    end
    return out
end

--- 订阅状态改变。返回的 cancel 只注销观察者，绝不影响任务。
---@param callback fun()
---@return { cancel: fun() }
function Tasks.watch(callback)
    watchers[callback] = true
    return { cancel = function() watchers[callback] = nil end }
end

return Tasks
