--[[--
节流 / 防抖（跑在 UIManager 任务队列上）。

  local Timing = require("utils.timing")

  -- 防抖：停手 wait 秒后只跑最后一次
  local d = Timing.debounce(0.3, function(q) ... end)
  d("foo")
  d:cancel()

  -- 节流：wait 秒内最多跑一次（立刻执行，随后锁定）
  local t = Timing.throttle(1.0, function() ... end)
  t()
  t:cancel()

@module koplugin.book.utils.timing
--]]

local UIManager = require("ui/uimanager")

local Timing = {}

--- 防抖（trailing）：连续调用只保留最后一次，安静 wait 秒后执行。
--- 返回可调用 handle；调用即重新计时，`:cancel()` 取消已调度任务。
---@param wait number|nil 安静等待秒数；nil/非法按 0（立即执行）
---@param fn fun(...: any) 到期后用最后一次参数调用
---@return MoonTimingHandle
function Timing.debounce(wait, fn)
    wait = tonumber(wait) or 0
    if type(fn) ~= "function" then
        error("Timing.debounce: fn must be function", 2)
    end

    local scheduled
    local last_n
    local last_args
    local handle = {}

    local function fire()
        scheduled = nil
        local n, args = last_n, last_args
        last_n, last_args = nil, nil
        if not args then
            return
        end
        fn(unpack(args, 1, n))
    end

    --- 取消已调度的 trailing 回调，并丢弃待执行参数
    function handle:cancel()
        if scheduled then
            UIManager:unschedule(scheduled)
            scheduled = nil
        end
        last_n, last_args = nil, nil
    end

    setmetatable(handle, {
        __call = function(_, ...)
            -- select("#") 保留尾部 nil；#t 会截断
            last_n = select("#", ...)
            last_args = { ... }
            if scheduled then
                UIManager:unschedule(scheduled)
            end
            if wait <= 0 then
                fire()
                return
            end
            scheduled = fire
            UIManager:scheduleIn(wait, fire)
        end,
    })

    return handle
end

--- 节流（leading）：立刻执行，随后 wait 秒内忽略调用。
--- 返回可调用 handle；`:cancel()` 解除锁定并取消解锁定时器。
---@param wait number|nil 锁定秒数；nil/非法按 0（每次都执行）
---@param fn fun(...: any): any 立即执行的函数；返回值原样传出
---@return MoonTimingHandle
function Timing.throttle(wait, fn)
    wait = tonumber(wait) or 0
    if type(fn) ~= "function" then
        error("Timing.throttle: fn must be function", 2)
    end

    local locked = false
    local handle = {}

    local function on_unlock()
        locked = false
    end

    --- 取消锁定窗口，允许立即再次触发
    function handle:cancel()
        if locked then
            UIManager:unschedule(on_unlock)
            locked = false
        end
    end

    setmetatable(handle, {
        __call = function(_, ...)
            if locked then
                return
            end
            if wait <= 0 then
                return fn(...)
            end
            locked = true
            UIManager:scheduleIn(wait, on_unlock)
            return fn(...)
        end,
    })

    return handle
end

return Timing

--- Timing.debounce / throttle 返回值；可调用且可 :cancel()
---@class MoonTimingHandle
---@field cancel fun(self: MoonTimingHandle) 取消已调度任务
