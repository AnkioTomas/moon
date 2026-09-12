--[[-- 有前光但没有环境光传感器时，自动亮度必须保持不可用。
@module tests.ui.auto_brightness_no_sensor_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["utils.settings"] = function()
    return {
        get = function() return { auto_brightness_enabled = false } end,
        saveSection = function() error("device without ALS must not save settings") end,
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
        scheduleIn = function() error("device without ALS must not schedule") end,
        unschedule = function() end,
    }
end

local AutoBrightness = require("ui.auto_brightness")
Assert.is_false(AutoBrightness:isSupported())
Assert.is_false(AutoBrightness:start())
Assert.is_false(AutoBrightness:isEnabled())
