--[[--
节流 / 防抖（经 UIManager 调度，不堵事件循环）。

  local Timing = require("utils.timing")

  local d = Timing.debounce(function(q)
      -- wait 秒内多次调用，只跑最后一次
  end, 0.3)
  d("foo")
  d:cancel()

  local t = Timing.throttle(function()
      -- 立刻执行；wait 秒内（墙钟）再调丢弃
  end, 60)
  t()
  t:cancel()

@module koplugin.book.utils.timing
--]]

local UIManager = require("ui/uimanager")

local Timing = {}

---@class TimingHandle
---@field cancel fun(self: TimingHandle|nil)

--- 构造可调用句柄：`h(...)` 触发，`h:cancel()` 取消挂起。
---@param invoke fun(...)
---@param cancel fun()
---@return TimingHandle
local function handle(invoke, cancel)
    local h = {}
    --- 取消挂起的调用（节流句柄则是清掉上次执行时间，下次调用立即放行）。
    function h:cancel()
        cancel()
    end
    return setmetatable(h, {
        __call = function(_, ...)
            return invoke(...)
        end,
    })
end

--- 防抖（trailing）：wait 秒内多次调用，只执行最后一次参数。
---@param fn function
---@param wait number 秒（>= 0）
---@return TimingHandle
function Timing.debounce(fn, wait)
    if type(fn) ~= "function" then
        error("Timing.debounce: fn must be function", 2)
    end
    wait = tonumber(wait)
    if not wait or wait < 0 then
        error("Timing.debounce: wait must be >= 0", 2)
    end

    local n_args
    local args
    local fire
    fire = function()
        local n = n_args
        local a = args
        n_args = nil
        args = nil
        if a then
            fn(unpack(a, 1, n))
        end
    end

    return handle(function(...)
        n_args = select("#", ...)
        args = { ... }
        UIManager:unschedule(fire)
        UIManager:scheduleIn(wait, fire)
    end, function()
        UIManager:unschedule(fire)
        n_args = nil
        args = nil
    end)
end

--- 节流（leading）：立刻执行；wait 秒内（os.time 墙钟）后续调用丢弃。
--- 适合「最小间隔」类限流；亚秒精度勿用（os.time 粒度 1s）。
---@param fn function
---@param wait number 秒（>= 0）
---@return TimingHandle
function Timing.throttle(fn, wait)
    if type(fn) ~= "function" then
        error("Timing.throttle: fn must be function", 2)
    end
    wait = tonumber(wait)
    if not wait or wait < 0 then
        error("Timing.throttle: wait must be >= 0", 2)
    end

    local last_at = nil

    return handle(function(...)
        local now = os.time()
        if last_at and now - last_at < wait then
            return
        end
        last_at = now
        return fn(...)
    end, function()
        last_at = nil
    end)
end

return Timing
