--[[--
主体：时间天气。左右两栏同构排版；左右顺序和天气地点由组件设置配置。

@module koplugin.book.desktop.pages.home.clock_weather
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Clock = require("desktop.pages.home.clock")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local MoonSettings = require("utils.settings")
local Theme = require("ui.themes")
local Weather = require("desktop.pages.home.weather")
local _ = require("gettext")

local ORDER_WEATHER = "weather_left"
local ORDER_CLOCK = "clock_left"

---@class BookHomeClockWeather : BookHomeComponent
---@field clock BookHomeClock|nil
---@field weather BookHomeWeather|nil
local M = {
    id = "clock_weather",
    label = _("时间天气"),
    icon = "nest_clock_farsight_analog",
}
setmetatable(M, require("desktop.pages.home.base"))
M.__index = M

M.ORDER_WEATHER = ORDER_WEATHER
M.ORDER_CLOCK = ORDER_CLOCK

--- 与时钟同高：左右两栏并排，天气栏是不带预报的小卡片。
---@return BookHomeHeightSpec
function M:heightRange()
    return { height = Clock.contentHeight() }
end

--- 读取时间天气组件的左右顺序；未知配置回退到天气在左。
---@return string
function M.order()
    local value = MoonSettings.get("desktop.pages.home").home_clock_weather_order
    if value == ORDER_CLOCK then return ORDER_CLOCK end
    return ORDER_WEATHER
end

--- 规范化并保存时间天气组件的左右顺序。
---@param value string 当前设置项的值
function M.saveOrder(value)
    local home = MoonSettings.get("desktop.pages.home")
    home.home_clock_weather_order = value == ORDER_CLOCK and ORDER_CLOCK or ORDER_WEATHER
    MoonSettings.save("desktop.pages.home", home)
end

--- 编辑态设置：天气地点 + 左右顺序。
---@param desktop BookDesktop
function M:showSettings(desktop)
    require("ui.themes.widgets.sheet"):new{
        title = M.label,
        items = {
            { text = _("天气地点"), callback = function() Weather:showSettings(desktop) end },
            -- 按钮是动作：当前时间在左就写「天气在左」。
            { text = M.order() == ORDER_CLOCK and _("天气在左") or _("时间在左"), callback = function()
                M.saveOrder(M.order() == ORDER_WEATHER and ORDER_CLOCK or ORDER_WEATHER)
                desktop:onEvent("home_refresh")
            end },
        },
    }:show()
end

--- 惰性创建时钟和天气子组件。
---@param self BookHomeClockWeather 当前视图或布局实例
local function ensureKids(self)
    self.clock = self.clock or Clock:new{ home = self.home }
    self.weather = self.weather or Weather:new{ home = self.home }
end

--- 按左右顺序配置组装时钟和天气子组件，两个子项共用等分尺寸。
---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    ensureKids(self)
    local w, h = opts.width, opts.height
    local gap = Theme.px(Theme.current().space.sm)
    local col_opts = { width = math.max(1, math.floor((w - gap) / 2)), height = h }
    local weather_part = self.weather:build(ctx, col_opts)
    local clock_part = self.clock:build(ctx, col_opts)
    local left, right = weather_part, clock_part
    if M.order() == ORDER_CLOCK then left, right = clock_part, weather_part end
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        HorizontalGroup:new{ align = "center", left, HorizontalSpan:new{ width = gap }, right },
    }
end

function M:onActivate()
    ensureKids(self)
    self.clock:activate()
    self.weather:activate()
end

---@param event string
function M:onEvent(event)
    if self.weather then self.weather:onEvent(event) end
end

function M:onDeactivate()
    self.clock:deactivate()
    self.weather:deactivate()
end

function M:onDestroy()
    if self.clock then self.clock:destroy() end
    if self.weather then self.weather:destroy() end
    self.clock, self.weather = nil, nil
end

return M
