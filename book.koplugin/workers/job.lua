--[[--
一次性任务。kind 决定是否 fork，以及父进程隔多久看一眼结果。

  instant  不 fork，nextTick（闭包应在约 200ms 内结束，否则卡 UI）
  light    fork，0.5s 收结果
  medium   fork，2s
  heavy    fork，5s

Job.run 对 fork 任务只做发布；workers.system 按设备性能限流。
子进程禁止碰 sqlite；库操作必须走 instant。

@module koplugin.book.workers.job
--]]

local ffi = require("ffi")
local ffiUtil = require("ffi/util")
local Posix = require("ffi/posix")
local Protocol = require("workers.protocol")
local logger = require("utils.log")

local Job = {}
Job.__index = Job

--- fork 子进程里为 true。父进程这份永远是 false。
local in_child = false


function Job.inSubProcess()
    return in_child
end

local READ_CHUNK = 64 * 1024
local KINDS = {
    instant = 0,
    light = 0.5,
    medium = 2,
    heavy = 5,
}

---@param fd number|nil
local function closeFd(fd)
    if not fd then return end
    pcall(function() ffi.C.close(fd) end)
end

---@param callback function|nil
local function notify(callback, ...)
    if callback then pcall(callback, ...) end
end

---@param fd number
---@param message table
---@return boolean|nil, string|nil
local function writeFrame(fd, message)
    local ok, frame = pcall(Protocol.encode, message)
    if not ok then return nil, tostring(frame) end
    local wrote_ok, count = pcall(Posix.write, fd, ffi.cast("const char *", frame), #frame, true)
    if not wrote_ok or count ~= #frame then
        return nil, "job pipe write failed: " .. tostring(count)
    end
    return true
end

---@param ui table|nil
---@param pid number|nil
---@param poll number
local function reap(ui, pid, poll)
    if not ui or not pid or ffiUtil.isSubProcessDone(pid) then return end
    ui:scheduleIn(poll, function() reap(ui, pid, poll) end)
end

function Job:_arm()
    if not self.poll_fn then
        self.poll_fn = function() self:_poll() end
    else
        self.ui:unschedule(self.poll_fn)
    end
    self.ui:scheduleIn(self.poll, self.poll_fn)
end

function Job:_release()
    if self.ui then
        if self.timeout_fn then self.ui:unschedule(self.timeout_fn) end
        if self.poll_fn then self.ui:unschedule(self.poll_fn) end
    end
    closeFd(self.read_fd)
    self.read_fd = nil
    self.poll_fn = nil
    self.timeout_fn = nil
    reap(self.ui, self.pid, self.poll or KINDS.light)
end

---@param state "done"|"failed"|"cancelled"
---@param result any
---@param err string|nil
function Job:_teardown(state, result, err)
    self.state = state
    self.error = err
    if state ~= "done" and self.pid then
        ffiUtil.terminateSubProcess(self.pid)
    end
    logger.dbg("book.worker", self.name, self.kind, state, err or "")
    if state == "done" then
        notify(self.on_done, result)
    elseif state == "failed" then
        notify(self.on_failed, err)
    else
        notify(self.on_cancelled, self)
    end
    self:_release()
    if self._slotted then
        self._slotted = false
        require("workers.system"):release()
    end
end

---@param state "done"|"failed"|"cancelled"
---@param result any
---@param err string|nil
function Job:_finish(state, result, err)
    if self.settled then return end
    self.settled = true
    self:_teardown(state, result, err)
end

function Job:cancel()
    if self.settled then
        return
    end
    if self.kind ~= "instant" and not self._slotted then
        self.settled = true
        self.state = "cancelled"
        logger.dbg("book.worker", self.name, self.kind, "cancelled", "")
        notify(self.on_cancelled, self)
        return
    end
    self:_finish("cancelled")
end

Job.abort = Job.cancel

function Job:_dispatch(message)
    if message.type == "done" then
        self:_finish("done", message.result)
    elseif message.type == "failed" then
        self:_finish("failed", nil, message.error or "job failed")
    end
end

function Job:_read()
    if not self.read_fd then return end
    while true do
        local available = ffiUtil.getNonBlockingReadSize(self.read_fd)
        if not available or available <= 0 then return end
        local size = math.min(available, READ_CHUNK)
        local buffer = ffi.new("char[?]", size)
        local ok, count = pcall(Posix.read, self.read_fd, buffer, size, false)
        if not ok then
            self:_finish("failed", nil, "job pipe read failed: " .. tostring(count))
            return
        end
        local messages, err = Protocol.feed(self.decoder, ffi.string(buffer, count))
        if not messages then
            self:_finish("failed", nil, err or "worker protocol failed")
            return
        end
        for _, message in ipairs(messages) do self:_dispatch(message) end
        if self.settled or count < size then return end
    end
end

function Job:_poll()
    if self.settled then return end
    self:_read()
    if self.settled then return end
    if self.pid and ffiUtil.isSubProcessDone(self.pid) then
        self:_read()
        local ok, err = Protocol.finish(self.decoder)
        self:_finish("failed", nil, ok and "job exited without result" or err)
        return
    end
    self:_arm()
end

---@param self table
---@param worker fun(): any
local function runInstant(self, worker)
    self.ui = require("ui/uimanager")
    self.poll_fn = function()
        if self.settled then return end
        self.state = "running"
        local ok, result = xpcall(worker, debug.traceback)
        if self.settled then return end
        if ok then
            self:_finish("done", result)
        else
            self:_finish("failed", nil, tostring(result))
        end
    end
    self.ui:nextTick(self.poll_fn)
    return self
end

--- 真正 fork。只由 system 在拿到槽位后调用。
function Job:_start()
    self._slotted = true
    local worker = self._worker
    self._worker = nil
    self.decoder = Protocol.newDecoder()
    local pid, read_fd = ffiUtil.runInSubProcess(function(_, write_fd)
        in_child = true
        local function send(message) return writeFrame(write_fd, message) end
        local ok, result = xpcall(worker, debug.traceback)
        if ok then
            local sent, err = send({ type = "done", result = result })
            if not sent then send({ type = "failed", error = err }) end
        else
            send({ type = "failed", error = tostring(result) })
        end
    end, true)

    if not pid then
        self:_finish("failed", nil, tostring(read_fd))
        return
    end

    self.pid, self.read_fd = pid, read_fd
    self.state = "running"
    self.ui = require("ui/uimanager")
    self:_arm()
    local timeout = tonumber(self.timeout)
    if timeout and timeout > 0 then
        self.timeout_fn = function()
            self:_finish("failed", nil, "timeout")
        end
        self.ui:scheduleIn(timeout, self.timeout_fn)
    end
end

---@param worker fun(): any
---@param opts { name: string, kind: "instant"|"light"|"medium"|"heavy", on_done: function|nil, on_failed: function|nil, on_cancelled: function|nil, timeout: number|nil }
---@return table
function Job.run(worker, opts)
    assert(type(worker) == "function", "workers.job.run: worker must be function")
    opts = opts or {}
    assert(type(opts.name) == "string" and opts.name ~= "",
        "workers.job.run: opts.name required")
    local poll = KINDS[opts.kind]
    assert(poll, "workers.job.run: kind must be instant|light|medium|heavy")
    local self = setmetatable({
        name = opts.name,
        kind = opts.kind,
        poll = poll,
        timeout = opts.timeout,
        state = "queued",
        on_done = opts.on_done,
        on_failed = opts.on_failed,
        on_cancelled = opts.on_cancelled,
    }, Job)
    logger.dbg("book.worker queued", self.name, self.kind)

    if opts.kind == "instant" then
        return runInstant(self, worker)
    end

    self._worker = worker
    require("workers.system"):publish(self)
    return self
end

return Job
