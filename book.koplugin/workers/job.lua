--[[--
可执行任意闭包的一次性后台 Job。

闭包在 fork 时被子进程继承，而不是通过 IPC 序列化；进度和最终结果才走
JSON 管道。每个 Job 自己挂入 UIManager 事件循环，结束或取消后自行摘除。

@module koplugin.book.workers.job
--]]

local ffi = require("ffi")
local ffiUtil = require("ffi/util")
local Posix = require("ffi/posix")
local Protocol = require("workers.protocol")
local Context = require("workers.context")
local logger = require("utils.log")
local Perf = require("utils.perf")

local Job = {}
Job.__index = Job

---@alias WorkerJobState "queued"|"running"|"done"|"failed"|"cancelled"

---@class WorkerJob
---@field id number
---@field name string
---@field state WorkerJobState
---@field pid number|nil
---@field progress WorkerProgress|nil
---@field error string|nil
---@field cancel fun(self: WorkerJob)
---@field abort fun(self: WorkerJob)
---@field status fun(self: WorkerJob): WorkerJobStatus
---@field on_progress fun(value: WorkerProgress, job: WorkerJob)|nil
---@field on_done fun(result: any)|nil
---@field on_failed fun(err: string)|nil
---@field on_state fun(state: WorkerJobState, job: WorkerJob)|nil
---@field on_settled fun(job: WorkerJob)|nil
---@field on_cancelled fun(job: WorkerJob)|nil

---@class WorkerJobStatus
---@field id number
---@field name string
---@field state WorkerJobState
---@field pid number|nil
---@field progress WorkerProgress|nil
---@field error string|nil

---@class WorkerJobOptions
---@field name string 稳定任务名，用于日志和诊断
---@field on_progress fun(value: WorkerProgress, job: WorkerJob)|nil
---@field on_message fun(value: WorkerProgress, job: WorkerJob)|nil
---@field on_done fun(result: any)|nil
---@field on_failed fun(err: string)|nil
---@field on_state fun(state: string, job: WorkerJob)|nil
---@field on_settled fun(job: WorkerJob)|nil
---@field on_cancelled fun(job: WorkerJob)|nil
---@field timeout number|nil

---@class WorkerJobInternal: WorkerJob
---@field decoder WorkerDecoder
---@field ui table
---@field read_fd number|nil
---@field attached boolean
---@field settled boolean
---@field reaping boolean
---@field started_at number
---@field timeout_fn fun()|nil
---@field _setState fun(self: WorkerJobInternal, state: WorkerJobState, err: string|nil)
---@field _detach fun(self: WorkerJobInternal)
---@field _release fun(self: WorkerJobInternal)
---@field _settle fun(self: WorkerJobInternal, state: WorkerJobState, result: any, err: string|nil, reaping: boolean|nil)
---@field _fail fun(self: WorkerJobInternal, err: string)
---@field _dispatch fun(self: WorkerJobInternal, message: WorkerMessage)
---@field _read fun(self: WorkerJobInternal)
---@field waitEvent fun(self: WorkerJobInternal)

local READ_CHUNK = 64 * 1024
local next_id = 0
local active = {}

---@param fd number|nil
---@return nil
local function closeFd(fd)
    if fd then pcall(ffi.C.close, fd) end
end

---@param fd number
---@param message WorkerMessage
---@return boolean|nil, string|nil
local function writeFrame(fd, message)
    local ok, frame = pcall(Protocol.encode, message)
    if not ok then return nil, tostring(frame) end
    local ptr = ffi.cast("const char *", frame)
    local wrote_ok, count = pcall(Posix.write, fd, ptr, #frame, true)
    if not wrote_ok or count ~= #frame then
        return nil, "job pipe write failed: " .. tostring(count)
    end
    return true
end

---@param callback function|nil
---@param ... any
---@return nil
local function notify(callback, ...)
    if callback then pcall(callback, ...) end
end

---@param state "queued"|"running"|"done"|"failed"|"cancelled"
---@param err string|nil
---@return nil
---@param self WorkerJobInternal
function Job:_setState(state, err)
    if self.state == state then return end
    self.state = state
    self.error = err
    logger.dbg("book.worker state", self.name, "#" .. self.id, state, err or "")
    notify(self.on_state, state, self)
end

---@return nil
---@param self WorkerJobInternal
function Job:_detach()
    if not self.attached then return end
    self.attached = false
    self.ui:removeZMQ(self)
end

---@return nil
---@param self WorkerJobInternal
function Job:_release()
    if self.timeout_fn then self.ui:unschedule(self.timeout_fn) end
    closeFd(self.read_fd)
    self.read_fd = nil
    self:_detach()
end

---@param state "done"|"failed"|"cancelled"
---@param result any
---@param err string|nil
---@param reaping boolean|nil
---@return nil
---@param self WorkerJobInternal
function Job:_settle(state, result, err, reaping)
    if self.settled then return end
    self.settled = true
    self:_setState(state, err)
    logger.dbg("book.perf worker", self.name, "#" .. self.id,
        Perf.elapsedMs(self.started_at), "ms", state)
    if reaping == nil and self.pid then
        reaping = not ffiUtil.isSubProcessDone(self.pid)
    end
    self.reaping = reaping and true or false
    active[self.id] = nil
    if state == "done" then
        notify(self.on_done, result)
    elseif state == "failed" then
        notify(self.on_failed, err)
    elseif state == "cancelled" then
        notify(self.on_cancelled, self)
    end
    notify(self.on_settled, self)
    if not self.reaping then self:_release() end
end

---@param err string
---@return nil
---@param self WorkerJobInternal
function Job:_fail(err)
    if self.settled then return end
    if self.pid then ffiUtil.terminateSubProcess(self.pid) end
    self:_settle("failed", nil, err, true)
end

---@param message WorkerMessage
---@return nil
---@param self WorkerJobInternal
function Job:_dispatch(message)
    if message.type == "started" then
        self:_setState("running")
    elseif message.type == "progress" then
        self.progress = message.value
        notify(self.on_progress, message.value, self)
    elseif message.type == "done" then
        self:_settle("done", message.result)
    elseif message.type == "failed" then
        self:_settle("failed", nil, message.error or "job failed")
    end
end

---@return nil
---@param self WorkerJobInternal
function Job:_read()
    if not self.read_fd then return end
    while true do
        local available = ffiUtil.getNonBlockingReadSize(self.read_fd)
        if not available or available <= 0 then return end
        local size = math.min(available, READ_CHUNK)
        local buffer = ffi.new("char[?]", size)
        local ok, count = pcall(Posix.read, self.read_fd, buffer, size, false)
        if not ok then
            self:_fail("job pipe read failed: " .. tostring(count))
            return
        end
        local messages, err = Protocol.feed(self.decoder, ffi.string(buffer, count))
        if not messages then
            self:_fail(err or "worker protocol failed")
            return
        end
        for _, message in ipairs(messages) do self:_dispatch(message) end
        if self.settled or count < size then return end
    end
end

--- UIManager 调用点；只收 IPC 和回调，不执行业务闭包。
---@return nil
---@param self WorkerJobInternal
function Job:waitEvent()
    if self.settled then
        if self.reaping and self.pid and ffiUtil.isSubProcessDone(self.pid) then
            self.reaping = false
            self:_release()
        end
        return nil
    end
    self:_read()
    if self.settled then return nil end
    if self.pid and ffiUtil.isSubProcessDone(self.pid) then
        self:_read()
        local ok, err = Protocol.finish(self.decoder)
        self:_settle("failed", nil, ok and "job exited without result" or err, false)
    end
    return nil
end

---@return nil
---@param self WorkerJobInternal
function Job:cancel()
    if self.settled then return end
    if self.pid then ffiUtil.terminateSubProcess(self.pid) end
    local reaping = self.pid and not ffiUtil.isSubProcessDone(self.pid)
    self:_settle("cancelled", nil, nil, reaping)
end

Job.abort = Job.cancel

---@return WorkerJobStatus
---@param self WorkerJobInternal
function Job:status()
    return {
        id = self.id,
        name = self.name,
        state = self.state,
        pid = self.pid,
        progress = self.progress,
        error = self.error,
    }
end

---@param worker fun(context: WorkerContext): any
---@param opts WorkerJobOptions|nil
---@return WorkerJobInternal
function Job.run(worker, opts)
    assert(type(worker) == "function", "workers.job.run: worker must be function")
    opts = opts or {}
    assert(type(opts.name) == "string" and opts.name ~= "",
        "workers.job.run: opts.name required")
    next_id = next_id + 1
    local self = setmetatable({
        id = next_id,
        name = opts.name,
        started_at = Perf.now(),
        state = "queued",
        decoder = Protocol.newDecoder(),
        on_progress = opts.on_progress or opts.on_message,
        on_done = opts.on_done,
        on_failed = opts.on_failed,
        on_state = opts.on_state,
        on_settled = opts.on_settled,
        on_cancelled = opts.on_cancelled,
    }, Job)
    logger.dbg("book.worker queued", self.name, "#" .. self.id)
    notify(self.on_state, "queued", self)

    local pid, read_fd = ffiUtil.runInSubProcess(function(_, write_fd)
        ---@param message WorkerMessage
        ---@return boolean|nil, string|nil
        local function send(message) return writeFrame(write_fd, message) end
        Context.enter(send)
        local ok, result = xpcall(function()
            assert(send({ type = "started" }))
            return worker(Context)
        end, debug.traceback)
        Context.leave()
        if ok then
            local sent, err = send({ type = "done", result = result })
            if not sent then send({ type = "failed", error = err }) end
        else
            send({ type = "failed", error = tostring(result) })
        end
    end, true)

    if not pid then
        self:_settle("failed", nil, tostring(read_fd))
        return self
    end

    self.pid, self.read_fd = pid, read_fd
    self.ui = require("ui/uimanager")
    self.attached = true
    self.ui:insertZMQ(self)
    local timeout = tonumber(opts.timeout)
    if timeout and timeout > 0 then
        self.timeout_fn = function()
            if not self.settled then
                ffiUtil.terminateSubProcess(self.pid)
                self:_settle("failed", nil, "timeout", true)
            end
        end
        self.ui:scheduleIn(timeout, self.timeout_fn)
    end
    active[self.id] = self
    return self
end

---@param id number
---@return WorkerJobInternal|nil
function Job.get(id)
    return active[id]
end

---@return WorkerJobStatus[]
function Job.list()
    local out = {}
    for _, job in pairs(active) do out[#out + 1] = job:status() end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

---@return nil
function Job.stop()
    local jobs = active
    active = {}
    for _, job in pairs(jobs) do job:cancel() end
end

return Job
