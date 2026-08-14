--[[--
子进程任务：`runInSubProcess` + 固定 100ms UI 轮询，不堵事件循环。

  local Task = require("utils.task")

  local job = Task.run(function(pid, write_fd)
      -- 此处已在子进程；Task.inSubProcess() == true
      -- 勿闭包捕获主进程 userdata。
  end, {
      pipe = true,              -- 可选；结果经 FD 回传
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

local Task = {}

--- 内部固定轮询间隔（秒），不对外暴露。
local POLL_INTERVAL = 0.1

--- 仅子进程 worker 内为 true（fork 后子进程自己的 Lua 状态）。
local in_subprocess = false

--- 当前是否在 Task 拉起的子进程里。
---@return boolean
function Task.inSubProcess()
    return in_subprocess
end

---@class MoonTask
---@field abort fun(self: MoonTask|nil)

--- 在子进程跑 worker，主进程轮询直到结束、超时或 abort。
---@param worker fun(pid: number, write_fd: any|nil, read_fd: any|nil)
---@param opts {
---   pipe?: boolean,
---   timeout?: number,
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
    local use_pipe = opts.pipe and true or false
    local timeout = tonumber(opts.timeout)
    if timeout and timeout <= 0 then
        timeout = nil
    end

    local settled = false
    local pid
    local read_fd
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
        if not ffiUtil.isSubProcessDone(pid) then
            UIManager:scheduleIn(POLL_INTERVAL, check)
            return
        end
        local raw = read_fd and ffiUtil.readAllFromFD(read_fd) or nil
        settleDone(raw)
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
