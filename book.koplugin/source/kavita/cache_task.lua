--[[--
漫画缓存的后台任务登记：把「缓存这一批卷」登记成一条 passive 后台任务。

kamare 仍是唯一的执行者与写入者：这里不下载、不取消队列，只按本批 chapterId 轮询
`queue_state` / `status`，把进度报给 `workers.tasks`，让顶栏「后台任务」看得到、缓存期间不自动休眠、
关掉卷列表后仍有完成提示。队列是全局的（按服务器过滤），所以进度只数本批自己那几卷。

  local handle = CacheTask.track{ series = series, entries = entries }  -- 入队成功后
  handle.mute(true)   -- 页面自己的进度框负责提示时静音（默认不静音，由任务 toast）
  handle.add(more)    -- 同一部又有卷入队 / 重试失败项：并进同一条任务，终态清掉重新观察
  handle.cancel()     -- 只停轮询，不动 kamare 队列（队列控制仍走 Cache.queuePause/Resume/Retry）

没有 `workers.tasks`（旧核或单独装扩展）时 track 返回 nil，调用方退回页内进度框。

@module source.kavita.cache_task
--]]

local _ = require("gettext")
local T = require("ffi/util").template
local Cache = require("source.kavita.cache")

local CacheTask = {}

--- 轮询间隔：下载中 1 秒；暂停时 5 秒（用户可能几小时不处理，别每秒读一次索引）。
local POLL_SECONDS = 1
local PAUSED_SECONDS = 5
--- 连续这么多拍都看不到本批的队列项、也没落地：kamare 重启 / 队列被清，按中断收尾。
local MAX_IDLE_TICKS = 5

--- 函数内 require：旧核没有 workers.tasks 时返回 nil，不抛错。
---@return table|nil
local function tasksModule()
    local ok, mod = pcall(require, "workers.tasks")
    if ok and type(mod) == "table" and type(mod.enqueue) == "function" and type(mod.get) == "function" then
        return mod
    end
    return nil
end

---@param text string|nil
local function toast(text)
    if not text then return end
    require("ui.themes.widgets.toast"):new{ text = text, timeout = 2 }:show()
end

--- 队列条目按 chapterId 归一成字符串键（kamare 的键可能是数字）。
---@param queue table|nil
---@return table
local function queueEntries(queue)
    local out = {}
    for key, entry in pairs(type(queue) == "table" and queue.entries or {}) do
        out[tostring(key)] = entry
    end
    return out
end

---@param queue table|nil
---@return boolean
local function queuePaused(queue)
    return type(queue) == "table" and (queue.state == "paused" or queue.pause_reason ~= nil)
end

---@param st table
local function stopTimer(st)
    if st.timer then
        require("ui/uimanager"):unschedule(st.timer)
        st.timer = nil
    end
end

---@param st table
local function schedule(st)
    if st.settled or st.timer then return end
    local delay = st.paused and PAUSED_SECONDS or POLL_SECONDS
    local timer
    timer = function()
        st.timer = nil
        st:poll()
    end
    st.timer = timer
    require("ui/uimanager"):scheduleIn(delay, timer)
end

--- 本批任务的可变状态：track / 轮询 / handle 共用一份。
---@param opts table
---@return table
local function newState(opts)
    local series = type(opts.series) == "table" and opts.series or {}
    local st = {
        title = series.title or series.stable_id,
        ids = {},          -- 顺序数组，去重
        seen = {},         -- tostring(id) -> true
        landed = {},       -- tostring(id) -> 终态（已缓存或失败）
        failed = {},       -- tostring(id) -> true
        titles = {},       -- tostring(id) -> 卷名
        total = 0,
        ok_count = 0,
        idle = 0,
        muted = false,
        paused = false,
        settled = false,
        timer = nil,
        report = nil,
        call_done = nil,
    }

    --- 并进一批卷：新 id 追加；已有的清掉终态，重试 / 重新入队后下一拍重新观察。
    ---@param entries table[]
    function st:add(entries)
        for _idx, entry in ipairs(type(entries) == "table" and entries or {}) do
            local id = entry.chapterId or entry.chapter_id or entry.id
            if id ~= nil then
                local key = tostring(id)
                if not self.seen[key] then
                    self.seen[key] = true
                    self.ids[#self.ids + 1] = id
                end
                self.landed[key] = nil
                self.failed[key] = nil
                self.titles[key] = entry.title
            end
        end
        self.total = #self.ids
        self.idle = 0
    end

    --- 报表一次；没有 run 之前（还在排队）跳过。
    ---@param text string|nil
    function st:emit(text)
        if self.report then self.report(text, self.ok_count, self.total) end
    end

    --- 收尾：只结算一次；静音时不出提示（页面自己的进度框已经报过）。
    ---@param interrupted boolean|nil
    ---@return table
    function st:settle(interrupted)
        if self.settled then return { ok = false } end
        self.settled = true
        stopTimer(self)
        -- 最后一卷落地的那一拍直接 settle，不会走到 poll 末尾的 emit：补报一次最终计数，
        -- 否则任务卡片停在上一拍的「已完成 2/3」。
        self:emit(nil)
        local failed_count = 0
        for key in pairs(self.failed) do
            if self.seen[key] then failed_count = failed_count + 1 end
        end
        if not self.muted then
            if interrupted and self.ok_count == 0 then
                toast(_("缓存已中断"))
            elseif failed_count == 0 then
                toast(T(_("已缓存 %1 卷"), self.total))
            else
                toast(T(_("%1 卷成功，%2 卷失败"), self.ok_count, failed_count))
            end
        end
        local result = {
            ok = failed_count == 0 and not interrupted,
            cached = self.ok_count,
            total = self.total,
            failed = failed_count,
            interrupted = interrupted or nil,
        }
        if self.call_done then self.call_done(result) end
        return result
    end

    --- 每一拍：数本批的终态，报进度；全部落地就收尾。
    function st:poll()
        self.timer = nil
        if self.settled then return end
        local queue = Cache.queueState()
        local entries = queueEntries(queue)
        local remaining, queued_any = 0, false
        for _idx, id in ipairs(self.ids) do
            local key = tostring(id)
            if not self.landed[key] then
                local queued = entries[key]
                if queued and queued.state == "failed" then
                    self.landed[key] = true
                    self.failed[key] = true
                elseif Cache.isCached(Cache.status(id)) then
                    self.landed[key] = true
                else
                    remaining = remaining + 1
                    if queued then queued_any = true end
                end
            end
        end
        local ok_count = 0
        for _idx, id in ipairs(self.ids) do
            local key = tostring(id)
            if self.landed[key] and not self.failed[key] then ok_count = ok_count + 1 end
        end
        self.ok_count = ok_count
        self.paused = queuePaused(queue)
        if remaining <= 0 then return self:settle() end
        if self.paused then
            self.idle = 0
            self:emit(queue and queue.pause_reason == "low_space" and _("空间不足，已暂停") or _("已暂停"))
        else
            local current = queue and queue.current_chapter_id
            self:emit(current ~= nil and self.titles[tostring(current)] or nil)
            if queued_any then
                self.idle = 0
            else
                -- 本批的卷既没在队列里、也没落地：kamare 重启 / 队列被清，不能永远挂着。
                self.idle = self.idle + 1
                if self.idle >= MAX_IDLE_TICKS then return self:settle(true) end
            end
        end
        schedule(self)
    end

    return st
end

--- 登记一条 passive 任务；同一部书已有未结束的任务就并进去。
---@param opts { series: table|nil, entries: table[], key: string|nil }
---@return table|nil handle mute(value): …; add(entries): …; cancel(): …
function CacheTask.track(opts)
    opts = type(opts) == "table" and opts or {}
    local entries = type(opts.entries) == "table" and opts.entries or {}
    if #entries == 0 then return nil end
    if not Cache.available("queue") then return nil end
    local Tasks = tasksModule()
    if not Tasks then return nil end
    local series = type(opts.series) == "table" and opts.series or {}
    local key = "kavita-cache\0" .. tostring(opts.key or series.stable_id or series.title or "series")

    local live = Tasks.get(key)
    if live and live._cache_state then
        live._cache_state:add(entries)
        live._cache_state:emit(nil)
        return live._cache_handle
    end

    local st = newState(opts)
    st:add(entries)
    local handle = {}
    handle.mute = function(value) st.muted = value ~= false end
    handle.add = function(more)
        st:add(more)
        st:emit(nil)
    end
    handle.cancel = function() stopTimer(st) end

    local task = {
        key = key,
        kind = "cache",
        title = st.title,
        passive = true,
        -- 队列暂停（空间不足 / 等网络）时不再压自动休眠：一停几小时不能把电耗光。
        hold = function() return not st.paused end,
        run = function(report, done)
            st.report, st.call_done = report, done
            st:emit(nil)
            schedule(st)
            return { cancel = function() stopTimer(st) end }
        end,
    }
    local queued = Tasks.enqueue(task)
    if not queued then return nil end
    queued._cache_state = st
    queued._cache_handle = handle
    handle.task = queued
    return handle
end

return CacheTask
