--[[--
旋转动作：短按兼容、传感器三策略、原生状态实时显示、同值不切换、无传感器不提供长按。

@module tests.features.panel.rotate_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
local sensor = true
package.preload["device"] = function() return { hasGSensor = function() return sensor end } end
local flags, events = {}, {}
G_reader_settings = { isTrue = function(_self, name) return flags[name] == true end }
package.preload["ui/event"] = function()
    return { new = function(_self, name, value) return { name = name, value = value } end }
end
package.preload["ui/uimanager"] = function()
    return {
        broadcastEvent = function(_self, event)
            events[#events + 1] = event
            if event.name == "SetLockGSensor" then flags.input_lock_gsensor = event.value
            elseif event.name == "ToggleGSensor" then flags.input_ignore_gsensor = not flags.input_ignore_gsensor
            else error("unexpected event " .. event.name) end
        end,
    }
end
local path = "features.panel.actions.desktop.rotate"
local Rotate = require(path)
Assert.eq(Rotate.event, "IterateRotation")
Assert.is_nil(Rotate.run)
for _idx, pair in ipairs({ { false, false }, { false, true }, { true, false }, { true, true } }) do
    for choice = 1, 3 do
        flags.input_ignore_gsensor, flags.input_lock_gsensor = pair[1], pair[2]
        Rotate.hold()
        local sheet = Themed.last("sheet")
        local current = pair[1] and 3 or (pair[2] and 2 or 1)
        Assert.eq(sheet.items[current].variant, "primary")
        sheet.items[choice].callback()
        Assert.eq(flags.input_ignore_gsensor, choice == 3)
        Assert.eq(flags.input_lock_gsensor, choice == 3 and pair[2] or choice == 2)
        local before = #events
        sheet.items[choice].callback()
        Assert.len(events, before, "重复选择当前策略不能切换回去")
    end
end
flags.input_ignore_gsensor, flags.input_lock_gsensor = false, false
Assert.is_false(Rotate.active())
Assert.eq(Rotate.label(), "旋转·自动")
flags.input_lock_gsensor = true
Assert.is_true(Rotate.active())
Assert.eq(Rotate.label(), "旋转·仅180°")
flags.input_ignore_gsensor = true
Assert.eq(Rotate.label(), "旋转·关闭自动")
Rotate.hold()
local sheet = Themed.last("sheet")
flags.input_ignore_gsensor, flags.input_lock_gsensor = false, false
local before = #events
sheet.items[1].callback()
Assert.len(events, before, "弹窗打开期间外部设置变了，回调仍须读当前原生状态")
sensor = false
package.loaded[path] = nil
Rotate = require(path)
Assert.eq(Rotate.event, "IterateRotation")
Assert.is_nil(Rotate.hold)
Assert.is_nil(Rotate.active)
Assert.is_nil(Rotate.label)
return true
