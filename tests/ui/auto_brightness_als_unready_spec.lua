--[[-- LIPC 能读到 alsLux 但值为 -1 时，必须判定为有传感器。
@module tests.ui.auto_brightness_als_unready_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["utils.settings"] = function()
    return {
        get = function() return { auto_brightness_enabled = false } end,
        saveSection = function() end,
    }
end

package.preload["device"] = function()
    return {
        hasFrontlight = function() return true end,
        getPowerDevice = function()
            return { fl_min = 0, fl_max = 24, setIntensity = function() end }
        end,
    }
end

package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function() end,
        unschedule = function() end,
    }
end

package.preload["liblipclua"] = function()
    return {
        init = function()
            return {
                get_int_property = function(_, service, property)
                    Assert.eq(service, "com.lab126.powerd")
                    if property == "alsLux" then return -1 end
                    return nil
                end,
                set_int_property = function() end,
                close = function() end,
            }
        end,
    }
end

local AutoBrightness = require("ui.auto_brightness")
Assert.is_true(AutoBrightness:isSupported(), "alsLux=-1 表示传感器未就绪，不是没有传感器")
Assert.is_true(AutoBrightness:start())
Assert.is_true(AutoBrightness:isEnabled())
AutoBrightness:shutdown()
