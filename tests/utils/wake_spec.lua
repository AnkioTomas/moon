--[[--
utils.wake 唤醒看门狗：只记日志不关屏；唤醒后又睡下去的新锁屏还挂着不算异常，连日志都不记。

@module tests.utils.wake_spec
--]]
---@diagnostic disable: undefined-field, inject-field

local Assert = require("support.assert")

local warns = {}
package.preload["utils.log"] = function()
    return {
        info = function() end,
        warn = function(...) warns[#warns + 1] = table.concat({ ... }, " ") end,
        flushSync = function() end,
    }
end
package.preload["utils.paths"] = function()
    return { root = function() return "/tmp" end }
end

local scheduled = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _secs, fn) scheduled[#scheduled + 1] = fn end,
        unschedule = function(_self, fn)
            for i, f in ipairs(scheduled) do
                if f == fn then table.remove(scheduled, i) break end
            end
        end,
        setDirty = function() end,
        close = function() end,
    }
end
package.preload["ui/time"] = function()
    return { now = function() return 0 end, to_s = function(v) return v end }
end

local device = { screen_saver_mode = false }
package.preload["device"] = function() return device end

local closed = 0
package.preload["ui/screensaver"] = function()
    return {
        close_widget = function() closed = closed + 1 end,
        cleanup = function() end,
    }
end

_G.G_reader_settings = { readSetting = function() return "disable" end }

local Wake = require("utils.wake")

local function fire()
    local fns = scheduled
    scheduled = {}
    for _idx, fn in ipairs(fns) do fn() end
end

-- 唤醒后锁屏还挂着、期间没有新睡眠：只记 WARN，绝不关屏。
do
    warns, closed = {}, 0
    device.screen_saver_mode = true
    Wake.resume()
    fire()
    Assert.eq(closed, 0)
    Assert.eq(#warns, 1)
    Assert.matches(warns[1], "still shown")
end

-- 唤醒后又睡下去了（新锁屏刚上）：看门狗不许碰。
do
    warns, closed = {}, 0
    Wake.suspend()
    Wake.resume()
    Wake.suspend()
    device.screen_saver_mode = true
    fire()
    Assert.eq(closed, 0)
    Assert.len(warns, 0)
end

-- 唤醒后锁屏已正常关掉：什么都不做。
do
    warns, closed = {}, 0
    Wake.resume()
    device.screen_saver_mode = false
    fire()
    Assert.eq(closed, 0)
    Assert.len(warns, 0)
end
