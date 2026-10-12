--[[--
features.remote 生命周期 × 锁屏密码：锁着时不起服，解锁后补起；锁着再休眠不丢「要恢复」。
@module tests.features.remote.lifecycle_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local locked = false
local waiters = {}
package.loaded["features.passcode"] = {
    afterUnlock = function(key, fn)
        if not locked then return fn() end
        waiters[key] = fn
    end,
}
local function unlock()
    locked = false
    for key, fn in pairs(waiters) do
        waiters[key] = nil
        fn()
    end
end

local guarded = {}
package.loaded["ui.guard"] = {
    wrap = function(label, fn)
        return function(...)
            guarded[#guarded + 1] = label
            return fn(...)
        end
    end,
}

local Remote = require("features.remote")
local running, starts = false, 0
Remote.isRunning = function() return running end
Remote.start = function()
    running, starts = true, starts + 1
    return true
end
Remote.stop = function() running = false end
local autostart = false
Remote.autostartOn = function() return autostart end

-- 没锁：照旧，休眠前在跑就恢复。
running = true
Remote.onSuspend()
Remote.onResume()
Assert.is_true(running)
Assert.eq(starts, 1)

-- 锁着唤醒：不起服，解锁后才起。
Remote.onSuspend()
locked = true
Remote.onResume()
Assert.is_false(running)
-- 解锁前又休眠、再唤醒：要恢复的标记还在，排队只留一个。
Remote.onSuspend()
Remote.onResume()
Assert.is_false(running)
unlock()
Assert.is_true(running)
Assert.eq(starts, 2)
Assert.is_false(Remote._resume)

-- 没在跑也没开自启：唤醒不排队。
Remote.onSuspend()
running = false
Remote._resume = false
locked = true
Remote.onResume()
Assert.is_nil(waiters.remote)

-- 冷启动自启：锁着时排队，解锁后下一 tick 起服。
autostart = true
package.loaded["features.remote.screenshot"] = { onCreate = function() end }
Remote.onCreate()
Stubs.flush()
Assert.is_false(running)
unlock()
Stubs.flush()
Assert.is_true(running)
Assert.contains(guarded, "remote autostart", "nextTick 起服经 guard")
