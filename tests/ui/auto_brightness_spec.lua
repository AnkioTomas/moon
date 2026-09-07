--[[-- 自动亮度控制器离线用例：能力探测、自动写入与手动调光退出。
@module tests.ui.auto_brightness_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["logger"] = function() return { err = function() end } end

local settings = { auto_brightness_enabled = false }
package.preload["utils.settings"] = function()
    return {
        get = function(_, section)
            return settings
        end,
        saveSection = function() end,
    }
end

local powerd = {
    fl_min = 0,
    fl_max = 24,
    fl_intensity = 6,
    writes = 0,
}
function powerd:setIntensity(value)
    self.writes = self.writes + 1
    self.fl_intensity = value
end
function powerd:turnOffFrontlight()
    self.fl_intensity = 0
end
function powerd:frontlightIntensity()
    return self.fl_intensity
end

package.preload["device"] = function()
    return {
        hasFrontlight = function() return true end,
        getPowerDevice = function() return powerd end,
    }
end

local scheduled = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, delay, fn)
            scheduled[#scheduled + 1] = { delay = delay, fn = fn }
        end,
        unschedule = function(_, fn)
            for i = #scheduled, 1, -1 do
                if scheduled[i].fn == fn then table.remove(scheduled, i) end
            end
        end,
    }
end

local native_values = {}
package.preload["liblipclua"] = function()
    return {
        init = function()
            return {
                get_int_property = function(_, service, property)
                    Assert.eq(service, "com.lab126.powerd")
                    if property == "alsLux" then return 100 end
                    if property == "flAuto" then return 1 end
                    error("unexpected property: " .. tostring(property))
                end,
                set_int_property = function(_, service, property, value)
                    Assert.eq(service, "com.lab126.powerd")
                    Assert.eq(property, "flAuto")
                    native_values[#native_values + 1] = value
                end,
                close = function() end,
            }
        end,
    }
end

local AutoBrightness = require("ui.auto_brightness")
Assert.is_true(AutoBrightness:isSupported())
Assert.is_false(AutoBrightness:isEnabled())

Assert.is_true(AutoBrightness:start())
Assert.is_true(AutoBrightness:isEnabled())
Assert.is_true(settings.auto_brightness_enabled)
Assert.eq(scheduled[#scheduled].delay, 0.2)
scheduled[#scheduled].fn()
Assert.eq(powerd.fl_intensity, 13)
Assert.eq(powerd.writes, 1)
Assert.is_true(AutoBrightness:isEnabled(), "自动写入不能被自己的 PowerD hook 关闭")
Assert.eq(AutoBrightness.native_auto_before, 1)

-- 真正改变档位的外部写入必须立即关闭自动亮度；原写入仍然要完成。
powerd:setIntensity(15)
Assert.is_false(AutoBrightness:isEnabled())
Assert.is_false(settings.auto_brightness_enabled)
Assert.eq(powerd.fl_intensity, 15)
Assert.eq(AutoBrightness.native_auto_before, nil)
Assert.eq(native_values[1], 0)
Assert.eq(native_values[2], 1)

AutoBrightness:shutdown()
