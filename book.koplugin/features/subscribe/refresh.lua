--[[--
订阅刷新的后台任务：跟书架同步一样进 workers.tasks（kind = sync），不挂在页面上，切页签 / 打开文章 / 看书时继续跑。

全进程只有一个刷新任务（固定 key）：在跑或排队时再要刷新的源并进去（同一个源不重复），不另起并发；
单个源（点某个源刷新 / 网页端单源刷新）插到队首，下一个就刷它，不用等前面整轮刷完。
最多 CONCURRENCY 个源并发拉条目列表（只拉列表，不下载正文），内存里只有待刷新的行。手动刷新 follow 时弹前台进度窗（可转后台），
自动刷新（打开订阅页时刷全部过期源，quiet）静默入队、失败不弹 toast、在任务列表里看进度。每个源刷完、整轮结束都通知 watch 的监听者（订阅页重画）。
队列满时退回直接跑。

  Refresh.start(feeds, { more = false, follow = true, on_feed = function(feed, added, err) end })

@module koplugin.book.features.subscribe.refresh
--]]

local Guard = require("ui.guard")
local Tasks = require("workers.tasks")
local logger = require("utils.log")
local T = require("ffi/util").template
local _ = require("gettext")

local Refresh = {}

Refresh.KEY = "sync\0subscribe"

--- 同时在飞的源数（各源多在不同主机，串行时总耗时 = 各源延迟之和）。
Refresh.CONCURRENCY = 4

---@type { feed: table, more: boolean|nil, on_feed: function|nil }[]|nil 本轮待刷新；nil = 没有在跑
local queue
---@type integer
local done_count, total = 0, 0
---@type table<integer, fun(text: string|nil, done: boolean)>
local listeners = {}
---@type string|nil 正在做的事
local status

---@type boolean 本轮没进队列、直接跑
local direct = false

--- 任务在排队时被用户 / 队列取消不会走到 run：发现任务没了就把残留的本轮清掉。
local function settle()
    if not queue or direct then return end
    local task = Tasks.get(Refresh.KEY)
    if not task or task.done or task.state == "cancelled" or task.state == "finished" then
        queue, status, done_count, total = nil, nil, 0, 0
    end
end

local function notify(finished)
    for _idx, fn in ipairs(listeners) do Guard.call("subscribe.refresh listener", fn, status, finished) end
end

--- 监听进度（订阅页重画）；返回取消函数。
---@param fn fun(text: string|nil, finished: boolean)
---@return fun()
function Refresh.watch(fn)
    listeners[#listeners + 1] = fn
    return function()
        for i, f in ipairs(listeners) do
            if f == fn then table.remove(listeners, i) return end
        end
    end
end

--- 正在刷新时的状态文案；没在刷新返回 nil。
---@return string|nil
function Refresh.status()
    settle()
    return queue and (status or _("等待刷新订阅…")) or nil
end

---@param front boolean|nil 插到队首（单源刷新插队）；队里已有的同一源挪过来
local function push(feeds, opts, front)
    if front then
        for i = #feeds, 1, -1 do
            local feed = feeds[i]
            for j = #queue, 1, -1 do
                local e = queue[j]
                if e.feed.id == feed.id and (e.more or false) == (opts.more or false) and not e.on_feed then
                    table.remove(queue, j)
                    total = total - 1
                end
            end
            table.insert(queue, 1, { feed = feed, more = opts.more, on_feed = opts.on_feed })
            total = total + 1
        end
        return
    end
    for _idx, feed in ipairs(feeds) do
        local dup = false
        for _i, e in ipairs(queue) do
            if e.feed.id == feed.id and (e.more or false) == (opts.more or false) and not opts.on_feed then dup = true break end
        end
        if not dup then
            queue[#queue + 1] = { feed = feed, more = opts.more, on_feed = opts.on_feed }
            total = total + 1
        end
    end
end

--- 公众号授权失效弹窗：一轮最多一次，且 PROMPT_INTERVAL 内只弹一次（后台刷新别刷屏）。
Refresh.PROMPT_INTERVAL = 30 * 60
local prompted_at

---@param err any
---@return boolean
local function isMpAuth(err)
    local Mp = require("source.wechat.mp")
    return err ~= nil and tostring(err) == _(Mp.AUTH_EXPIRED)
end

local function promptMpAuth()
    local now = os.time()
    if prompted_at and now - prompted_at < Refresh.PROMPT_INTERVAL then return end
    prompted_at = now
    local Mp = require("source.wechat.mp")
    require("ui.themes.widgets.confirm"):new{ text = _(Mp.AUTH_EXPIRED), ok_text = _("知道了") }:show()
end

local function run(report, finish)
    local cancelled, failed = false, nil
    local mp_auth = false
    ---@type table<table, table|boolean> 在飞的条目 → 取消句柄
    local active, running = {}, 0
    local pump

    local function launch(entry)
        local feed = entry.feed
        status = T(_("正在刷新 %1…"), feed.title)
        report(status, done_count, total)
        notify(false)
        running = running + 1
        active[entry] = true
        local job = require("features.subscribe").refresh(feed, entry.more, function(added, err)
            if cancelled then return end
            active[entry] = nil
            running = running - 1
            done_count = done_count + 1
            if err then failed = failed or (tostring(feed.title) .. ": " .. tostring(err)) end
            if isMpAuth(err) then mp_auth = true end
            if entry.on_feed then Guard.call("subscribe.refresh on_feed", entry.on_feed, feed, added, err) end
            require("ui/uimanager"):nextTick(pump)
        end)
        if active[entry] then active[entry] = job or true end
    end

    pump = function()
        if cancelled then return end
        while queue and #queue > 0 and running < Refresh.CONCURRENCY do launch(table.remove(queue, 1)) end
        if running > 0 then return end
        queue, status, done_count, total = nil, nil, 0, 0
        notify(true)
        if mp_auth then promptMpAuth() end
        finish({ ok = failed == nil, err = failed })
    end

    pump()
    return {
        cancel = function()
            cancelled = true
            local rest = queue or {}
            for entry, job in pairs(active) do
                if type(job) == "table" and job.cancel then job:cancel() end
                table.insert(rest, 1, entry)
            end
            queue, status, done_count, total = nil, nil, 0, 0
            for _idx, e in ipairs(rest) do
                if e.on_feed then Guard.call("subscribe.refresh on_feed", e.on_feed, e.feed, nil, _("已取消")) end
            end
            notify(true)
        end,
    }
end

--- 刷新一组源（后台任务）。已有刷新在跑 / 排队时并进去，返回 false。
---@param feeds table[] SubDB 行
---@param opts { more?: boolean, follow?: boolean, quiet?: boolean, on_feed?: fun(feed: table, added: integer|nil, err: any) }|nil quiet = 自动刷新：失败不弹 toast
---@return boolean started 是否新起了一轮
function Refresh.start(feeds, opts)
    opts = opts or {}
    if #feeds == 0 then return false end
    settle()
    if queue then
        push(feeds, opts, #feeds == 1)
        local task = Tasks.get(Refresh.KEY)
        if opts.follow and task and not task.done then require("workers.ui.task_dialog").follow(task) end
        return false
    end
    queue, done_count, total, direct = {}, 0, 0, false
    push(feeds, opts)
    logger.dbg("subscribe refresh start", total)
    local task = Tasks.enqueue{
        key = Refresh.KEY, kind = "sync", title = _("订阅"), run = run,
        on_done = function(result)
            if not opts.follow and not opts.quiet and result and not result.ok and result.err then
                require("ui.themes.widgets.toast"):new{ text = tostring(result.err), timeout = 3 }:show()
            end
        end,
    }
    if task then
        if opts.follow then require("workers.ui.task_dialog").follow(task) end
    else
        direct = true
        local noop = function() end
        run(noop, noop)
    end
    notify(false)
    return true
end

--- 测试用：清状态。
function Refresh._reset()
    prompted_at = nil
    queue, status, done_count, total, listeners, direct = nil, nil, 0, 0, {}, false
end

return Refresh
