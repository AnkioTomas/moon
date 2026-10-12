--[[--
主体：天气预报。小天气卡片 + 底部一行未来预报（有逐小时按小时，没有按天）；
布局、取数、地点设置全部继承天气（weather.lua）。

@module koplugin.book.desktop.pages.home.weather_forecast
--]]

local _ = require("gettext")

---@class BookHomeWeatherForecast : BookHomeWeather
local M = setmetatable({
    id = "weather_forecast",
    label = _("每小时天气预报"),
    icon = "weather_mix",
    forecast = true,
}, require("desktop.pages.home.weather"))
M.__index = M

return M
