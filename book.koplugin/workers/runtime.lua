--[[--
一个执行域对应一个常驻子进程。

主进程只做非阻塞 IPC、队列和回调；实际 handler 永远在子进程执行。

  local Worker = require("workers.runtime").new({ handlers = { ... } })
  Worker:request("list_books", args, function(result, err) end)
  UIManager:insertZMQ(Worker)

@module koplugin.book.workers.runtime
--]]

local ffi = require("ffi")
local bit = require("bit")
local ffiUtil = require("ffi/util")
local Protocol = require("workers.protocol")

-- `ffi/util` 已加载 KOReader 的 posix_h 声明（fcntl/write/close/O_NONBLOCK）。
-- 不在此重复 cdef，避免把 write 的 ssize_t 错声明成 long。

local Runtime = {}
Runtime.__index = Runtime

---@class WorkerRequestHandle
---@field id number
---@field cancel fun(self: WorkerRequestHandle)

---@class WorkerDefinition
---@field name string|nil
---@field handlers table<string, fun(args: table|nil): any>
---@field init fun()|nil
---@field max_pending number|nil

---@class WorkerRuntime
---@field handlers table<string, fun(args: table|nil): any>
---@field init fun()|nil
---@field max_pending number
---@field pid number|nil
---@field read_fd number|nil
---@field write_fd number|nil
---@field decoder WorkerDecoder
---@field write_queue table[]
---@field write_head number
---@field requests table<number, table>
---@field next_id number
---@field state string
---@field restart_at number
---@field restart_delay number
---@field stopping boolean

local MAX_PENDING = 32
local READ_CHUNK = 64 * 1024
local WRITE_BUDGET = 128 * 1024
local RESTART_MAX_DELAY = 30

---@return number
local function now()
    return (ffiUtil.getTimestamp and ffiUtil.getTimestamp()) or os.clock()
end

---@param fd number
---@return boolean
local function setNonBlocking(fd)
    local ok = pcall(function()
        local flags = ffi.C.fcntl(fd, ffi.C.F_GETFL, 0)
        assert(flags >= 0, "fcntl get flags failed")
        assert(ffi.C.fcntl(fd, ffi.C.F_SETFL, bit.bor(flags, ffi.C.O_NONBLOCK)) == 0,
            "fcntl set nonblocking failed")
    end)
    return ok
end

---@param fd number|nil
---@return nil
local function closeFd(fd)
    if fd then pcall(ffi.C.close, fd) end
end

---@param opts WorkerDefinition
---@return WorkerRuntime
function Runtime.new(opts)
    opts = opts or {}
    assert(type(opts.handlers) == "table", "workers.runtime: handlers required")
    return setmetatable({
        handlers = opts.handlers,
        init = opts.init,
        max_pending = tonumber(opts.max_pending) or MAX_PENDING,
        pid = nil,
        read_fd = nil,
        write_fd = nil,
        decoder = Protocol.newDecoder(),
        write_queue = {},
        write_head = 1,
        requests = {},
        next_id = 0,
        state = "stopped",
        restart_at = 0,
        restart_delay = 0.25,
        stopping = false,
    }, Runtime)
end

---@return boolean
function Runtime:isRunning()
    return self.state == "starting" or self.state == "ready"
end

---@param self WorkerRuntime
---@return boolean
local function queueEmpty(self)
    return self.write_head > #self.write_queue
end

---@param self WorkerRuntime
---@param value table
---@param id number|nil
---@return boolean|nil, string|nil
function Runtime:_enqueue(value, id)
    local ok, frame = pcall(Protocol.encode, value)
    if not ok then return nil, frame end
    self.write_queue[#self.write_queue + 1] = { data = frame, offset = 1, id = id }
    return true
end

---@return nil
function Runtime:_closePipes()
    closeFd(self.read_fd)
    closeFd(self.write_fd)
    self.read_fd, self.write_fd = nil, nil
end

---@param err string
---@return nil
function Runtime:_failInflight(err)
    local calls = self.requests
    for _, item in pairs(calls) do
        if item.sent and not item.cancelled and item.callback then
            pcall(item.callback, nil, err)
            self.requests[item.id] = nil
        end
    end
end

---@param err string|nil
---@return nil
function Runtime:_markDead(err)
    if self.state == "stopped" then return end
    self:_closePipes()
    self.pid = nil
    self.state = "dead"
    self:_failInflight(err or "worker exited")
    -- 已发送/部分发送的帧不能在新 pipe 上重放；尚未写出的请求可以保留。
    local kept = {}
    for i = self.write_head, #self.write_queue do
        local frame = self.write_queue[i]
        local item = frame.id and self.requests[frame.id]
        if item and not item.sent then
            kept[#kept + 1] = frame
        end
    end
    self.write_queue, self.write_head = kept, 1
    -- 记录退避时间；没有工作时不拉起空转的子进程，但下一次 request 会复用它。
    if not self.stopping then
        self.restart_at = now() + self.restart_delay
        self.restart_delay = math.min(self.restart_delay * 2, RESTART_MAX_DELAY)
    end
end

---@return boolean|nil, string|nil
function Runtime:_start()
    if self:isRunning() then return true end
    if self.stopping then return nil, "worker stopping" end
    local Child = require("workers.child")
    local handlers = self.handlers
    local init = self.init
    local pid, read_fd, write_fd = ffiUtil.runInSubProcess(function(_, child_write, child_read)
        Child.run(child_read, child_write, handlers, init)
    end, "bidi")
    if not pid then
        self.state = "dead"
        self.restart_at = now() + self.restart_delay
        self.restart_delay = math.min(self.restart_delay * 2, RESTART_MAX_DELAY)
        return nil, read_fd
    end
    self.pid, self.read_fd, self.write_fd = pid, read_fd, write_fd
    setNonBlocking(self.read_fd)
    setNonBlocking(self.write_fd)
    self.decoder = Protocol.newDecoder()
    self.state = "starting"
    return true
end

---@return nil
function Runtime:_send()
    if not self.write_fd or queueEmpty(self) then return end
    local sent_total = 0
    while self.write_head <= #self.write_queue and sent_total < WRITE_BUDGET do
        local item = self.write_queue[self.write_head]
        local rest = #item.data - item.offset + 1
        local budget = math.min(rest, WRITE_BUDGET - sent_total)
        local ptr = ffi.cast("const char *", item.data) + item.offset - 1
        local write_ok, n = pcall(ffi.C.write, self.write_fd, ptr, budget)
        if not write_ok then
            self:_markDead("worker pipe write failed: " .. tostring(n))
            return
        end
        n = tonumber(n)
        if n and n > 0 then
            if item.id and self.requests[item.id] then
                -- 只要写出一个字节，就不能在新 pipe 上重放这个请求。
                self.requests[item.id].sent = true
            end
            item.offset = item.offset + n
            sent_total = sent_total + n
            if item.offset > #item.data then
                self.write_queue[self.write_head] = nil
                self.write_head = self.write_head + 1
            end
        else
            break -- EAGAIN/EPIPE；下一轮再试，退出由 isSubProcessDone 收口
        end
    end
    if queueEmpty(self) then
        self.write_queue = {}
        self.write_head = 1
    end
end

--- 把 Worker 接入 KOReader 主事件循环；调用一次即可。
---@return nil
function Runtime:attach()
    require("ui/uimanager"):insertZMQ(self)
end

--- 从 KOReader 主事件循环摘除 Worker。
---@return nil
function Runtime:detach()
    require("ui/uimanager"):removeZMQ(self)
end

---@return nil
function Runtime:_read()
    if not self.read_fd then return end
    local available = ffiUtil.getNonBlockingReadSize(self.read_fd)
    if not available or available <= 0 then return end
    local size = math.min(available, READ_CHUNK)
    local buffer = ffi.new("char[?]", size)
    local ok, n = pcall(require("ffi/posix").read, self.read_fd, buffer, size, false)
    if not ok then
        self:_markDead("worker pipe read failed: " .. tostring(n))
        return
    end
    local messages, err = Protocol.feed(self.decoder, ffi.string(buffer, n))
    if not messages then
        self:_markDead(err)
        return
    end
    for _, message in ipairs(messages) do
        self:_dispatch(message)
    end
end

---@param message WorkerMessage
---@return nil
function Runtime:_dispatch(message)
    if message.type == "ready" then
        self.state = "ready"
        self.restart_delay = 0.25
        return
    end
    if message.type == "fatal" then
        self:_markDead(message.error)
        return
    end
    if message.type ~= "response" then return end
    local item = self.requests[message.id]
    if not item then return end
    self.requests[message.id] = nil
    if not item.cancelled and item.callback then
        if message.ok then
            pcall(item.callback, message.result, nil)
        else
            pcall(item.callback, nil, message.error or "worker request failed")
        end
    end
end

--- UIManager/事件循环调用点；必须短，不执行业务 handler。
---@return nil
function Runtime:waitEvent()
    if self.state == "dead" and not self.stopping
        and self.write_head <= #self.write_queue and now() >= self.restart_at then
        self:_start()
    elseif self.state == "stopped" and #self.write_queue > 0 then
        self:_start()
    end
    if not self:isRunning() then return nil end
    self:_send()
    self:_read()
    if self.pid and ffiUtil.isSubProcessDone(self.pid) then
        local ok, err = Protocol.finish(self.decoder)
        self:_markDead(ok and "worker exited" or err)
    end
    return nil
end

---@param op string
---@param args table|nil
---@param callback fun(result: any, err: any)|nil
---@return WorkerRequestHandle|nil, string|nil
function Runtime:request(op, args, callback)
    if type(op) ~= "string" or op == "" then return nil, "invalid worker operation" end
    local queued = #self.write_queue - self.write_head + 1
    local active = 0
    for _ in pairs(self.requests) do active = active + 1 end
    if queued + active >= self.max_pending then return nil, "worker queue full" end
    self.next_id = self.next_id + 1
    local id = self.next_id
    self.requests[id] = { id = id, callback = callback, sent = false }
    local ok, err = self:_enqueue({ type = "request", id = id, op = op, args = args }, id)
    if not ok then
        self.requests[id] = nil
        return nil, err
    end
    if self.state == "stopped"
        or (self.state == "dead" and not self.stopping and now() >= self.restart_at) then
        self:_start()
    end
    return {
        id = id,
        cancel = function()
            local item = self.requests[id]
            if not item or item.cancelled then return end
            item.cancelled = true
            self:_enqueue({ type = "cancel", id = id })
        end,
    }
end

---@return nil
function Runtime:stop()
    if self.state == "stopped" then return end
    self.stopping = true
    if self:isRunning() then
        self:_enqueue({ type = "shutdown" })
        self:_send()
    end
    if self.pid and not ffiUtil.isSubProcessDone(self.pid) then
        ffiUtil.terminateSubProcess(self.pid)
    end
    self:_closePipes()
    self.pid = nil
    self.state = "stopped"
    local calls = self.requests
    self.requests = {}
    for _, item in pairs(calls) do
        if not item.cancelled and item.callback then
            pcall(item.callback, nil, "worker stopped")
        end
    end
    self.write_queue = {}
    self.write_head = 1
    self.stopping = false
end

return Runtime
