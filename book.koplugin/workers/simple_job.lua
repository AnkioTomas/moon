--[[--
基于 UIManager:nextTick 的轻量一次性任务。

不 fork，不建立 IPC，只把一次闭包推迟到下一轮 UI 事件循环。

@module koplugin.book.workers.simple_job
--]]
---@alias SimpleJobState "queued"|"running"|"done"|"failed"|"cancelled"

local SimpleJob = {}
SimpleJob.__index = SimpleJob

---@class SimpleJobOptions
---@field on_done fun(result: any)|nil
---@field on_failed fun(err: string)|nil
---@field on_state fun(state: SimpleJobState, job: SimpleJobHandle)|nil
---@field on_cancelled fun(job: SimpleJobHandle)|nil
---@field on_settled fun(job: SimpleJobHandle)|nil

---@class SimpleJobHandle
---@field state SimpleJobState
---@field result any
---@field error string|nil
---@field settled boolean
---@field on_done fun(result: any)|nil
---@field on_failed fun(err: string)|nil
---@field on_state fun(state: SimpleJobState, job: SimpleJobHandle)|nil
---@field on_cancelled fun(job: SimpleJobHandle)|nil
---@field on_settled fun(job: SimpleJobHandle)|nil
---@field cancel fun(self: SimpleJobHandle): boolean
---@field status fun(self: SimpleJobHandle): table

---@param callback function|nil
---@param ... any
---@return nil
local function notify(callback, ...)
    if callback then pcall(callback, ...) end
end

---@param self SimpleJobHandle
---@param state SimpleJobState
---@param result any
---@param err string|nil
local function settle(self, state, result, err)
    if self.settled then return end
    self.settled = true
    self.state = state
    self.result = result
    self.error = err
    notify(self.on_state, state, self)
    if state == "done" then
        notify(self.on_done, result)
    elseif state == "failed" then
        notify(self.on_failed, err)
    elseif state == "cancelled" then
        notify(self.on_cancelled, self)
    end
    notify(self.on_settled, self)
end

---@param self SimpleJobHandle
---@return boolean
function SimpleJob:cancel()
    if self.settled or self.state ~= "queued" then return false end
    settle(self, "cancelled")
    return true
end

---@param self SimpleJobHandle
---@return table
function SimpleJob:status()
    return {
        state = self.state,
        result = self.result,
        error = self.error,
    }
end

---@param fn fun(): any
---@param opts SimpleJobOptions|nil
---@return SimpleJobHandle
function SimpleJob.run(fn, opts)
    assert(type(fn) == "function", "workers.simple_job.run: function required")
    opts = opts or {}
    ---@type SimpleJobHandle
    local self = setmetatable({
        state = "queued",
        on_done = opts.on_done,
        on_failed = opts.on_failed,
        on_state = opts.on_state,
        on_cancelled = opts.on_cancelled,
        on_settled = opts.on_settled,
    }, SimpleJob)
    notify(self.on_state, "queued", self)

    local function execute()
        if self.settled then return end
        self.state = "running"
        notify(self.on_state, "running", self)
        local ok, result = xpcall(fn, debug.traceback)
        if ok then
            settle(self, "done", result)
        else
            settle(self, "failed", nil, tostring(result))
        end
    end

    require("ui/uimanager"):nextTick(execute)
    return self
end

SimpleJob.nextTick = SimpleJob.run

return SimpleJob
