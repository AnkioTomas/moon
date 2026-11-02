--[[--
防自动休眠：hold 置 / 还原 pause_auto_suspend 并按间隔补 InputEvent；poke 发一次 InputEvent。

@module tests.utils.awake_spec
--]]
---@diagnostic disable: undefined-field, missing-fields

local Assert = require("support.assert")

local events, scheduled, unscheduled = 0, {}, 0
local share = { pause_auto_suspend = true }
package.loaded["pluginshare"] = share
package.loaded["ui/uimanager"] = {
    event_hook = { execute = function(_, name) if name == "InputEvent" then events = events + 1 end end },
    scheduleIn = function(_, delay, fn) scheduled[#scheduled + 1] = { delay = delay, fn = fn } end,
    unschedule = function() unscheduled = unscheduled + 1 end,
}

package.loaded["utils.awake"] = nil
local Awake = require("utils.awake")

Awake.poke()
Assert.eq(events, 1)

Awake.hold("a", true)
Assert.is_true(Awake.held())
Assert.eq(events, 2, "升旗立即补一次")
Assert.eq(scheduled[1].delay, Awake.PULSE)
scheduled[1].fn()
Assert.eq(events, 3, "到点再补")
Assert.len(scheduled, 2, "继续排下一拍")

Awake.hold("a", true)
Awake.hold("b", true)
Assert.eq(events, 3, "重复升旗无操作")

Awake.hold("a", false)
Assert.is_true(Awake.held(), "还有持有者")
Assert.eq(unscheduled, 0)
Awake.hold("b", false)
Assert.is_false(Awake.held())
Assert.eq(unscheduled, 1)
Assert.is_true(share.pause_auto_suspend, "还原升旗前的原值")
scheduled[2].fn()
Assert.eq(events, 3, "降旗后残留的一拍不再补")
