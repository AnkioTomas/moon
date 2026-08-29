--[[--
章节全本缓存后台队列。

所有任务全局串行，避免多个详情页同时轰炸同一远端服务。任务只在本次
KOReader 进程存活期间保持；已成功章节落盘后，重试和再次入队都会跳过。

@module koplugin.book.source.cache_queue
--]]

require("l10n").apply()

local _ = require("gettext")

local Queue = {}

local pending = {}
local by_key = {}
local active
local waiting_retry
local watchers = {}
local change_scheduled = false

local MAX_ATTEMPTS = 3
local RETRY_DELAY_SECONDS = 15

--- 通知首页状态栏刷新；订阅者只是 UI 观察者，绝不拥有或取消任务。
local function flushChanged()
    change_scheduled = false
    for callback in pairs(watchers) do
        pcall(callback)
    end
end

local function changed()
    if change_scheduled then return end
    change_scheduled = true
    local ok, UIManager = pcall(require, "ui/uimanager")
    if ok and UIManager and UIManager.scheduleIn then
        UIManager:scheduleIn(0.25, flushChanged)
    else
        flushChanged()
    end
end

---@param source BookSource
---@param identity BookIdentity
---@return string
local function keyFor(source, identity)
    return tostring(source.id) .. "\0" .. tostring(identity.stable_id)
end

---@param err any
---@return boolean
local function retryable(err)
    local text = tostring(err or "")
    return text:find("HTTP 425", 1, true) ~= nil
        or text:find("shard md5 mismatch", 1, true) ~= nil
end

---@param job table
---@param result table
local function notify(job, result)
    local text
    if result.ok then
        text = _("全本缓存完成：") .. tostring(result.cached) .. " / "
            .. tostring(result.total) .. _(" 章")
    elseif result.total > 0 then
        text = _("全本缓存部分完成：") .. tostring(result.cached) .. " / "
            .. tostring(result.total) .. _(" 章")
        if result.failed > 0 then
            text = text .. "，" .. tostring(result.failed) .. _(" 章失败")
        end
        if result.err then text = text .. "\n" .. tostring(result.err) end
    else
        text = tostring(result.err or _("全本缓存失败"))
    end
    local ok, UIManager = pcall(require, "ui/uimanager")
    local ok_message, InfoMessage = pcall(require, "ui/widget/infomessage")
    if ok and ok_message then
        UIManager:show(InfoMessage:new{ text = text, timeout = 5 })
    end
end

local startNext

---@param job table
---@param result table
local function finish(job, result)
    job.done = true
    job.result = result
    by_key[job.key] = nil
    if active == job then active = nil end
    if waiting_retry == job then waiting_retry = nil end
    notify(job, result)
    changed()
    startNext()
end

---@param job table
---@param result table
local function retryOrFinish(job, result)
    if retryable(result.err) and job.attempt < MAX_ATTEMPTS then
        active = nil
        waiting_retry = job
        job.state = "retry_wait"
        local delay = RETRY_DELAY_SECONDS * (2 ^ (job.attempt - 1))
        local UIManager = require("ui/uimanager")
        job.retry_tick = function()
            job.retry_tick = nil
            if waiting_retry == job then waiting_retry = nil end
            if not job.cancelled then
                pending[#pending + 1] = job
                changed()
                startNext()
            end
        end
        UIManager:scheduleIn(delay, job.retry_tick)
        changed()
        startNext()
        return
    end
    finish(job, result)
end

--- 取一个后台任务执行；一次只跑一本书，减少服务端限流和内存占用。
startNext = function()
    if active then return end
    local job = table.remove(pending, 1)
    while job and job.cancelled do
        by_key[job.key] = nil
        job = table.remove(pending, 1)
    end
    if not job then return end
    active = job
    job.state = "running"
    job.attempt = job.attempt + 1
    changed()
    local ok, handle_or_err = pcall(job.source.cacheAllChaptersAsync, job.source, job.identity,
        function(cached, total)
            if job.cancelled then return end
            job.cached = tonumber(cached) or 0
            job.total = tonumber(total) or 0
            changed()
        end, function(success, cached, err, total, failed)
            if job.cancelled then return end
            retryOrFinish(job, {
                ok = success and true or false,
                cached = tonumber(cached) or 0,
                total = tonumber(total) or 0,
                failed = tonumber(failed) or 0,
                err = err,
            })
        end)
    if not ok then
        retryOrFinish(job, {
            ok = false, cached = 0, total = 0, failed = 0, err = handle_or_err,
        })
        return
    end
    job.handle = handle_or_err
end

--- 加入全本缓存后台队列。同一本书已在排队或运行时复用既有任务。
---@param source BookSource
---@param identity BookIdentity
---@return table|nil job
---@return boolean queued 是否新入队
function Queue.enqueue(source, identity)
    if not source or type(source.cacheAllChaptersAsync) ~= "function"
        or type(identity) ~= "table" or type(identity.stable_id) ~= "string"
        or identity.stable_id == "" then
        return nil, false
    end
    local key = keyFor(source, identity)
    if by_key[key] then return by_key[key], false end
    local job = {
        key = key,
        source = source,
        identity = identity,
        attempt = 0,
        state = "queued",
        done = false,
    }
    by_key[key] = job
    pending[#pending + 1] = job
    changed()
    startNext()
    return job, true
end

--- 当前队列状态，供首页顶栏展示；无任务返回 nil。
---@return { state: string, cached: integer, total: integer, pending: integer }|nil
function Queue.status()
    local job = active or waiting_retry or pending[1]
    if not job then return nil end
    return {
        state = job.state,
        cached = tonumber(job.cached) or 0,
        total = tonumber(job.total) or 0,
        pending = #pending + (active and 1 or 0) + (waiting_retry and 1 or 0),
    }
end

--- 返回当前任务快照：运行中/重试等待的任务在前，其余按入队顺序排列。
--- 返回副本，调用方不能修改队列内部状态。
---@return table[]
function Queue.tasks()
    local out = {}
    local function append(job, state)
        if not job then return end
        local identity = job.identity or {}
        local book = identity.book or {}
        out[#out + 1] = {
            state = state or job.state,
            source_id = identity.source_id or job.source and job.source.id,
            stable_id = identity.stable_id,
            title = book.title or identity.title or identity.stable_id,
            cached = tonumber(job.cached) or 0,
            total = tonumber(job.total) or 0,
            attempt = tonumber(job.attempt) or 0,
        }
    end
    append(active)
    append(waiting_retry)
    for _, job in ipairs(pending) do
        append(job, "queued")
    end
    return out
end

--- 订阅状态改变。返回的 cancel 只注销观察者，绝不影响缓存任务。
---@param callback fun()
---@return { cancel: fun() }
function Queue.watch(callback)
    if type(callback) == "function" then watchers[callback] = true end
    return { cancel = function() watchers[callback] = nil end }
end

return Queue
