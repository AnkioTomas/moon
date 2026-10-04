--[[--
时间天气：左右两栏各占一半，顺序可配；生命周期原样转给两个子组件；设置 Sheet 改顺序后通知首页刷新。
@module tests.desktop.pages.home.clock_weather_spec
--]]
local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Themed = require("support.theme_stubs")
Themed.install()

Kit.sections.home = { home_clock_weather_order = "weather_left", home_weather_city = "" }
package.preload["utils.text"] = function() return { trim = function(s) return s or "" end } end
local myrl, weather_fetches = 0, 0
package.preload["online.myrl"] = function()
    return { fetch = function() myrl = myrl + 1; return { cancel = function() end } end }
end
package.preload["online.weather"] = function()
    return {
        fetch = function() weather_fetches = weather_fetches + 1; return { cancel = function() end } end,
        iconUrl = function(key) return key end,
    }
end

local ClockWeather = require("desktop.pages.home.clock_weather")
Assert.eq(ClockWeather.order(), "weather_left")
ClockWeather.saveOrder("clock_left")
Assert.eq(ClockWeather.order(), "clock_left")
ClockWeather.saveOrder("bogus")
Assert.eq(ClockWeather.order(), "weather_left", "未知值回退天气在左")

local comp = ClockWeather:new()
local slot = comp:build({ desktop = {} }, { width = 600, height = 96 })
Assert.eq(slot:getSize().h, 96)
local row = slot[1][1]
Assert.eq(row[1], comp.weather.slot, "天气在左")
Assert.eq(row[3], comp.clock.slot)
Assert.eq(comp.clock.slot:getSize().w, 296, "两栏等分（减去 sm 间距）")

comp:activate()
Assert.is_true(comp.clock.active and comp.weather.active)
Assert.eq(myrl, 1)
Assert.eq(weather_fetches, 1)
comp:onEvent("home_refresh")
Assert.eq(weather_fetches, 2, "首页刷新转给天气")
comp:deactivate()
Assert.is_false(comp.clock.active or comp.weather.active)

ClockWeather.saveOrder("clock_left")
comp:refresh()
Assert.eq(slot[1][1][1], comp.clock.slot, "时间在左")
comp:destroy()
Assert.is_nil(comp.clock)
Assert.is_nil(comp.weather)

local events = {}
ClockWeather:showSettings({ onEvent = function(_, e) events[#events + 1] = e end })
local sheet = Themed.last("sheet")
Assert.eq(sheet.title, "时间天气")
Assert.eq(sheet.items[1].text, "天气地点")
Assert.eq(sheet.items[2].text, "天气在左", "按钮写动作：当前时间在左")
sheet.items[2].callback()
Assert.eq(ClockWeather.order(), "weather_left")
Assert.eq(events[1], "home_refresh")
sheet.items[1].callback()
Assert.eq(Themed.last("input").title, "天气地点")
