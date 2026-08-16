--[[--
子进程任务：`runInSubProcess` + 固定 100ms UI 轮询，不堵事件循环。
`pipe` 原始结果与 `on_message` 流式消息是两种互斥模式。

  local Task = require("utils.task")

  local job = Task.run(function(pid, write_fd)
      -- 此处已在子进程；Task.inSubProcess() == true
      -- 勿闭包捕获主进程 userdata。
      Task.post({ phase = "scan", count = 10 }) -- 仅 on_message 模式可用
  end, {
      on_message = function(message) -- 主进程回调，可安全更新 UI
      end,
      timeout = 30,             -- 秒；超时 abort 并 on_failed("timeout")
      on_done = function(raw)   -- 子进程结束；pipe 时 raw 为字符串，否则 nil
      end,
      on_failed = function(err) -- 启动失败 / 超时
      end,
  })
  job:abort()  -- 外部中止；此后不再触发 on_done / on_failed

轮询间隔固定，不可调。不负责业务成败判定——那是调用方的事。

@module koplugin.book.utils.task
--]]

local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local JSON = require("json")

local Task = {}

--- 内部固定轮询间隔（秒），不对外暴露。
local POLL_INTERVAL = 0.1

--- 仅子进程 worker 内为 true（fork 后子进程自己的 Lua 状态）。
local in_subprocess = false
local child_write_fd

--- 当前是否在 Task 拉起的子进程里。
---@return boolean
function Task.inSubProcess()
    return in_subprocess
end

--- 从 worker 向主进程发送一条可 JSON 编码的消息。
--- 仅在配置了 `on_message` 的 Task worker 内调用。
---@param message any
function Task.post(message)
    if not in_subprocess or not child_write_fd then
        error("Task.post: only available in on_message worker", 2)
    end
    local ok, payload = pcall(JSON.encode, message)
    if not ok or type(payload) ~= "string" then
        error("Task.post: " .. tostring(payload), 2)
    end
    local frame = string.format("%08x", #payload) .. payload
    if not ffiUtil.writeToFD(child_write_fd, frame) then
        error("Task.post: pipe write failed", 2)
    end
end

---@class MoonTask
---@field abort fun(self: MoonTask|nil)

--- 在子进程跑 worker，主进程轮询直到结束、超时或 abort。
---@param worker fun(pid: number, write_fd: any|nil, read_fd: any|nil)
---@param opts {
---   pipe?: boolean,
---   timeout?: number,
---   on_message?: fun(message: any),
---   on_done?: fun(raw: string|nil),
---   on_failed?: fun(err: any),
--- }|nil
---@return MoonTask
function Task.run(worker, opts)
    opts = opts or {}
    if type(worker) ~= "function" then
        error("Task.run: worker must be function", 2)
    end

    local on_done = opts.on_done
    local on_failed = opts.on_failed
    local on_message = opts.on_message
    if on_message ~= nil and type(on_message) ~= "function" then
        error("Task.run: on_message must be function", 2)
    end
    if on_message and opts.pipe then
        error("Task.run: pipe and on_message are mutually exclusive", 2)
    end
    local message_mode = on_message ~= nil
    local dispatch_message = on_message or function() end
    local use_pipe = message_mode or (opts.pipe and true or false)
    local timeout = tonumber(opts.timeout)
    if timeout and timeout <= 0 then
        timeout = nil
    end

    local settled = false
    local pid
    local read_fd
    local message_buffer = ""
    local check
    local on_timeout

    local function clearSchedules()
        if check then
            UIManager:unschedule(check)
        end
        if on_timeout then
            UIManager:unschedule(on_timeout)
        end
    end

    local function settleDone(raw)
        if settled then
            return
        end
        settled = true
        clearSchedules()
        if on_done then
            on_done(raw)
        end
    end

    local function settleFailed(err)
        if settled then
            return
        end
        settled = true
        clearSchedules()
        if on_failed then
            on_failed(err)
        end
    end

    --- 协议层失败（帧损坏 / 读管道失败 / 消息回调异常）：子进程行为已不可信，先杀再 settle。
    ---@param err any
    local function failProtocol(err)
        if pid and not ffiUtil.isSubProcessDone(pid) then
            ffiUtil.terminateSubProcess(pid)
        end
        settleFailed(err)
    end

    local function dispatchMessages(final)
        while #message_buffer >= 8 do
            local size = tonumber(message_buffer:sub(1, 8), 16)
            if not size then
                failProtocol("Task.run: invalid message frame")
                return false
            end
            if #message_buffer < size + 8 then
                break
            end
            local payload = message_buffer:sub(9, size + 8)
            message_buffer = message_buffer:sub(size + 9)
            local ok, message = pcall(JSON.decode, payload)
            if not ok then
                failProtocol("Task.run: invalid message: " .. tostring(message))
                return false
            end
            -- 消息回调是不可信的 UI 代码：炸了不能断轮询链，转协议失败
            local cb_ok, cb_err = pcall(dispatch_message, message)
            if not cb_ok then
                failProtocol("Task.run: on_message failed: " .. tostring(cb_err))
                return false
            end
            if settled then
                return false
            end
        end
        if final and #message_buffer > 0 then
            failProtocol("Task.run: incomplete message frame")
            return false
        end
        return true
    end

    local function readAvailableMessages()
        local size = ffiUtil.getNonBlockingReadSize(read_fd)
        if not size or size <= 0 then
            return true
        end
        local ffi = require("ffi")
        local buffer = ffi.new("char[?]", size)
        -- 不定长读（deny_short=false）：读到多少算多少，帧按缓冲区切；错误不能裸抛断轮询链
        local ok, read = pcall(require("ffi/posix").read, read_fd, buffer, size, false)
        if not ok then
            failProtocol("Task.run: pipe read failed: " .. tostring(read))
            return false
        end
        message_buffer = message_buffer .. ffi.string(buffer, read)
        return dispatchMessages(false)
    end

    ---@type MoonTask
    local handle = {}

    --- 外部中止：杀进程，不回调。
    function handle:abort()
        if settled then
            return
        end
        settled = true
        clearSchedules()
        if pid then
            ffiUtil.terminateSubProcess(pid)
        end
    end

    local second
    pid, second = ffiUtil.runInSubProcess(function(...)
        in_subprocess = true
        child_write_fd = select(2, ...)
        return worker(...)
    end, use_pipe or nil)
    if not pid then
        UIManager:nextTick(function()
            settleFailed(second)
        end)
        return handle
    end
    if use_pipe then
        read_fd = second
    end

    function check()
        if settled then
            return
        end
        if message_mode and not readAvailableMessages() then
            return
        end
        if not ffiUtil.isSubProcessDone(pid) then
            UIManager:scheduleIn(POLL_INTERVAL, check)
            return
        end
        local raw = read_fd and ffiUtil.readAllFromFD(read_fd) or nil
        if message_mode then
            message_buffer = message_buffer .. (raw or "")
            if dispatchMessages(true) then
                settleDone(nil)
            end
        else
            settleDone(raw)
        end
    end

    function on_timeout()
        if settled then
            return
        end
        if pid then
            ffiUtil.terminateSubProcess(pid)
        end
        settleFailed("timeout")
    end

    UIManager:scheduleIn(POLL_INTERVAL, check)
    if timeout then
        UIManager:scheduleIn(timeout, on_timeout)
    end

    return handle
end

return Task
