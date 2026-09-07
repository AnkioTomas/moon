--[[-- 不支持环境光传感器的设备不显示、不调度、不改设置。
@module tests.ui.auto_brightness_unsupported_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["utils.settings"] = function()
    return {
        get = function() return { auto_brightness_enabled = false } end,
        saveSection = function() error("unsupported device must not save settings") end,
    }
end
package.preload["device"] = function()
    return {
        hasFrontlight = function() return false end,
        getPowerDevice = function() error("unsupported device must not access PowerD") end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function() error("unsupported device must not schedule") end,
        unschedule = function() end,
    }
end

local AutoBrightness = require("ui.auto_brightness")
Assert.is_false(AutoBrightness:isSupported())
Assert.is_false(AutoBrightness:start())
Assert.is_false(AutoBrightness:isEnabled())
