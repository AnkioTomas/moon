--[[--
时间天气：左右组合；顺序由设置读写。

@module tests.ui.desktop.home.views.clock_weather_spec
--]]

local Assert = require("support.assert")

local function widget()
    return {
        new = function(_, opts)
            opts.getSize = function(self)
                return self.dimen or { w = 100, h = 40 }
            end
            opts.setText = function(self, text) self.text = text end
            return opts
        end,
    }
end
for _, name in ipairs({
    "container/centercontainer", "container/framecontainer",
    "horizontalgroup", "horizontalspan", "verticalgroup", "verticalspan",
    "textwidget",
}) do
    package.preload["ui/widget/" .. name] = widget
end
package.preload["ui/geometry"] = widget
package.preload["ffi/blitbuffer"] = function() return { COLOR_BLACK = 0 } end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n end,
        face = function() end,
        muted = function() return 0 end,
        dim = function() return 0 end,
    }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/util"] = function()
    return { template = function(s, a) return (s:gsub("%%1", tostring(a))) end }
end
local shown
package.preload["ui/uimanager"] = function()
    return {
        setDirty = function() end,
        scheduleIn = function() end,
        unschedule = function() end,
        show = function(_, widget) shown = widget end,
        close = function() end,
    }
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["online.myrl"] = function()
    return { fetch = function(_, _, cb) cb({}) return { cancel = function() end } end }
end
package.preload["online.weather"] = function()
    return {
        fetch = function(_, _, cb) cb({}) return { cancel = function() end } end,
        iconUrl = function() return "icon" end,
    }
end
package.preload["ui.components.image"] = function()
    return { widget = function(opts) return opts end }
end
package.preload["utils.text"] = function()
    return { trim = function(s) return tostring(s or "") end }
end

local home = { home_clock_weather_order = "weather_left", home_weather_city = "" }
package.preload["utils.settings"] = function()
    return {
        get = function() return home end,
        saveSection = function(_, section, values)
            if type(section) == "table" then
                home = section
            elseif values then
                home = values
            end
        end,
    }
end

-- saveSection signature in real code: saveSection("home", home)
package.loaded["utils.settings"] = nil
package.preload["utils.settings"] = function()
    return {
        get = function() return home end,
        saveSection = function(section_or_self, a, b)
            local values = b or a
            if type(values) == "table" then home = values end
        end,
    }
end

local ClockWeather = require("ui.desktop.home.views.clock_weather")
Assert.eq(ClockWeather.order(), "weather_left")
Assert.eq(ClockWeather.orderLabel(), "天气在左")

ClockWeather.saveOrder(ClockWeather.ORDER_CLOCK)
Assert.eq(home.home_clock_weather_order, "clock_left")
Assert.eq(ClockWeather.order(), "clock_left")
Assert.eq(ClockWeather.orderLabel(), "时间在左")

ClockWeather.saveOrder(ClockWeather.ORDER_WEATHER)
Assert.eq(ClockWeather.order(), "weather_left")

local comp = ClockWeather:new()
comp.lifecycle.state = "Resume"
local part = comp:build({ desktop = {} }, { width = 600, height = 96, y = 0 })
Assert.eq(part:getSize().h, 96)
Assert.not_nil(comp.clock)
Assert.not_nil(comp.weather)
comp:onPause()
comp:onDestroy()
Assert.is_nil(comp.clock)
Assert.is_nil(comp.weather)

local events = {}
shown = nil
ClockWeather:showSettings({
    onEvent = function(_, event) events[#events + 1] = event end,
    updateView = function() end,
})
Assert.eq(shown.title, "时间天气")
Assert.eq(shown.buttons[1][1].text, "天气地点")
Assert.eq(shown.buttons[2][1].text, "天气在左")
shown.buttons[2][1].callback()
Assert.eq(ClockWeather.order(), "clock_left")
Assert.eq(events[1], "home_changed")

return true
