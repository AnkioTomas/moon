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

-- LuaJIT/5.1 无 table.pack
local function pack(...)
    return { n = select("#", ...), ... }
end

local Timing = {}

--- 防抖（trailing）：连续调用只保留最后一次，安静 wait 秒后执行。
-- @param wait number 秒
-- @param fn function
-- @return MoonTimingHandle
function Timing.debounce(wait, fn)
    wait = tonumber(wait) or 0
    if type(fn) ~= "function" then
        error("Timing.debounce: fn must be function", 2)
    end

    local scheduled
    local last_args
    local handle = {}

    local function fire()
        scheduled = nil
        local args = last_args
        last_args = nil
        if not args then
            return
        end
        fn(unpack(args, 1, args.n))
    end

    function handle:cancel()
        if scheduled then
            UIManager:unschedule(scheduled)
            scheduled = nil
        end
        last_args = nil
    end

    setmetatable(handle, {
        __call = function(_, ...)
            last_args = pack(...)
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
-- @param wait number 秒
-- @param fn function
-- @return MoonTimingHandle
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
