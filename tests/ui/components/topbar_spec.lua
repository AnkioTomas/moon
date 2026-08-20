--[[--
ui.components.topbar 离线用例：状态项布局与图标档位。

@module tests.ui.components.topbar_spec
--]]

local Assert = require("support.assert")

local function widget()
    return {
        new = function(_, opts)
            return opts
        end,
    }
end

local icon_calls = {}
local text_calls = {}
local powerd = {
    capacity = 100,
    charging = false,
    light = 37,
}

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_WHITE = 255 }
end
package.preload["ui/widget/container/centercontainer"] = widget
package.preload["ui/widget/container/framecontainer"] = widget
package.preload["ui/geometry"] = widget
package.preload["ui/widget/horizontalgroup"] = widget
package.preload["ui/widget/horizontalspan"] = widget
package.preload["ui/widget/container/leftcontainer"] = widget
package.preload["ui/widget/linewidget"] = widget
package.preload["ui/widget/overlapgroup"] = widget
package.preload["ui/widget/container/rightcontainer"] = widget
package.preload["ui/widget/textwidget"] = function()
    return {
        new = function(_, opts)
            text_calls[#text_calls + 1] = opts.text
            return opts
        end,
    }
end
package.preload["ui/widget/verticalgroup"] = widget
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 800 end,
        },
        powerd = powerd,
        hasBattery = function() return true end,
        hasFrontlight = function() return true end,
    }
end
package.preload["datetime"] = function()
    return {
        secondsToHour = function(_, twelve_hour)
            return twelve_hour and "1:23 PM" or "13:23"
        end,
    }
end
package.preload["ui/network/manager"] = function()
    return {
        isWifiOn = function() return false end,
    }
end
package.preload["util"] = function()
    return {
        calcFreeMem = function() return 256, 1024 end,
    }
end
package.preload["ui.components.bookui"] = function()
    return {
        topBarH = function() return 40 end,
        pagePad = function() return 12 end,
        line = function() return 1 end,
        sz = function(n) return n end,
        face = function(name, size) return { name = name, size = size } end,
        rule = function() return 128 end,
    }
end
package.preload["ui.components.icon"] = function()
    return {
        label = function(opts)
            icon_calls[#icon_calls + 1] = { kind = "label", name = opts.name, text = opts.text }
            return opts
        end,
        widget = function(opts)
            icon_calls[#icon_calls + 1] = { kind = "widget", name = opts.name }
            return opts
        end,
    }
end
package.preload["utils.settings"] = function()
    return { activeSourceId = function() return "moon" end }
end
package.preload["source.registry"] = function()
    return { meta = function() return { name = "书库" } end }
end

_G.G_reader_settings = {
    isTrue = function(_, key)
        return key == "twelve_hour_clock"
    end,
}

function powerd:getCapacity()
    return self.capacity
end

function powerd:isCharging()
    return self.charging
end

function powerd:frontlightIntensity()
    return self.light
end

package.loaded["ui.components.topbar"] = nil
local TopBar = require("ui.components.topbar")

TopBar.build()

Assert.eq(icon_calls[1].name, "source")
Assert.eq(icon_calls[2].name, "memory")
Assert.eq(icon_calls[3].name, "wifi_off")
Assert.eq(icon_calls[4].name, "brightness_6")
Assert.eq(icon_calls[5].name, "battery_android_full")
Assert.eq(icon_calls[2].text, "75%")
Assert.eq(icon_calls[5].text, "100%")
Assert.contains(text_calls, "1:23 PM")

local normal_levels = {
    { 0, "battery_android_0" },
    { 15, "battery_android_1" },
    { 29, "battery_android_2" },
    { 43, "battery_android_3" },
    { 58, "battery_android_4" },
    { 72, "battery_android_5" },
    { 86, "battery_android_6" },
}
for _, case in ipairs(normal_levels) do
    icon_calls = {}
    powerd.capacity = case[1]
    powerd.charging = false
    TopBar.build()
    Assert.eq(icon_calls[5].name, case[2])
end

local charging_levels = {
    { 20, "battery_charging_20_2" },
    { 30, "battery_charging_30_2" },
    { 50, "battery_charging_50_2" },
    { 60, "battery_charging_60_2" },
    { 80, "battery_charging_80_2" },
    { 81, "battery_android_bolt" },
}
for _, case in ipairs(charging_levels) do
    icon_calls = {}
    powerd.capacity = case[1]
    powerd.charging = true
    TopBar.build()
    Assert.eq(icon_calls[5].name, case[2])
end
