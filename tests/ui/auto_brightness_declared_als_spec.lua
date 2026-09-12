--[[-- Kindle 已声明 ALS 时：-1 读数仍算支持，单次读失败不关自动亮度。
@module tests.ui.auto_brightness_declared_als_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

local settings = { auto_brightness_enabled = false }
package.preload["utils.settings"] = function()
    return {
        get = function() return settings end,
        saveSection = function() end,
    }
end

local powerd = {
    fl_min = 0,
    fl_max = 24,
    fl_intensity = 6,
    writes = 0,
    lipc_handle = {
        als = -1,
        get_int_property = function(self, service, property)
            Assert.eq(service, "com.lab126.powerd")
            if property == "alsLux" then return self.als end
            if property == "flAuto" then return 0 end
            error("unexpected property: " .. tostring(property))
        end,
        set_int_property = function(_, service, property)
            Assert.eq(service, "com.lab126.powerd")
            Assert.eq(property, "flAuto")
        end,
        close = function()
            error("borrowed PowerD lipc handle must not be closed")
        end,
    },
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
        hasLightSensor = function() return true end,
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

package.preload["liblipclua"] = function()
    error("declared ALS must reuse PowerD lipc handle")
end

local AutoBrightness = require("ui.auto_brightness")
Assert.is_true(AutoBrightness:isSupported(), "Device:hasLightSensor() 就必须显示自动亮度")
Assert.is_true(AutoBrightness:start())
Assert.is_true(AutoBrightness:isEnabled())

scheduled[#scheduled].fn()
Assert.eq(powerd.fl_intensity, 8, "alsLux=-1 按 0 lux 处理")
Assert.is_true(AutoBrightness:isEnabled())
Assert.is_true(AutoBrightness:isSupported())

powerd.lipc_handle.als = nil
AutoBrightness:sample()
Assert.is_true(AutoBrightness:isEnabled(), "声明有传感器时读失败不能关自动亮度")
Assert.is_true(AutoBrightness:isSupported())
Assert.eq(scheduled[#scheduled].delay, 60)

AutoBrightness:shutdown()
Assert.is_true(powerd.lipc_handle ~= nil)

-- 声明有传感器但 LIPC 完全不可用时，设置页仍应可点，采样失败也不能改成“不可用”。
powerd.lipc_handle = nil
Assert.is_true(AutoBrightness:isSupported())
Assert.is_true(AutoBrightness:start())
AutoBrightness:sample()
Assert.is_true(AutoBrightness:isEnabled())
Assert.is_true(AutoBrightness:isSupported())
AutoBrightness:shutdown()
