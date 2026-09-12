--[[--
主体：时间天气。左右两栏同构排版；左右顺序由设置页配置。

@module koplugin.book.ui.desktop.home.views.clock_weather
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Clock = require("ui.desktop.home.views.clock")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local MoonSettings = require("utils.settings")
local UI = require("ui.components.bookui")
local Weather = require("ui.desktop.home.views.weather")
local _ = require("gettext")

local GAP = 8
local ORDER_WEATHER = "weather_left"
local ORDER_CLOCK = "clock_left"

---@class BookHomeClockWeather : BookHomeComponent
---@field clock BookHomeClock|nil
---@field weather BookHomeWeather|nil
---@field desktop BookDesktop|nil
---@field region table|nil
local M = {
    id = "clock_weather",
    label = _("时间天气"),
    icon = "nest_clock_farsight_analog",
}
setmetatable(M, require("ui.desktop.home.views.base"))
M.__index = M

M.ORDER_WEATHER = ORDER_WEATHER
M.ORDER_CLOCK = ORDER_CLOCK

--- 返回当前组件的最小、首选和最大高度，供首页布局分配空间。
---@return BookHomeHeightRange range 首页布局使用的高度约束
function M:heightRange()
    return {
        min = UI.sz(80),
        preferred = UI.sz(96),
        max = UI.sz(120),
        grow = 0,
    }
end

--- 读取时间天气组件的左右顺序；未知配置回退到天气在左。
---@return string
function M.order()
    local value = MoonSettings.get("home").home_clock_weather_order
    if value == ORDER_CLOCK then return ORDER_CLOCK end
    return ORDER_WEATHER
end

--- 把当前左右顺序转换为设置页显示文案。
---@return string
function M.orderLabel()
    if M.order() == ORDER_CLOCK then
        return _("时间在左")
    end
    return _("天气在左")
end

--- 规范化并保存时间天气组件的左右顺序。
---@param value string 当前设置项的值
---@return nil
function M.saveOrder(value)
    local home = MoonSettings.get("home")
    home.home_clock_weather_order = value == ORDER_CLOCK and ORDER_CLOCK or ORDER_WEATHER
    MoonSettings.saveSection("home", home)
end

--- 惰性创建时钟和天气子视图，登记到父视图拥有的 children 映射。
---@param self BookHomeClockWeather 当前视图或布局实例
---@return nil
local function ensureKids(self)
    if not self.clock then
        self.clock = Clock:new()
        self.children.clock = self.clock
        self.clock.home = self.home
    end
    if not self.weather then
        self.weather = Weather:new()
        self.children.weather = self.weather
        self.weather.home = self.home
    end
end

--- 创建并登记时钟、天气子视图，再分别进入创建阶段。
---@return nil
function M:onCreate()
    ensureKids(self)
    self.clock:onCreate()
    self.weather:onCreate()
end

--- 按左右顺序配置组装时钟和天气子视图，两个子项共用等分尺寸。
---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    ensureKids(self)
    local w = opts.width
    local h = opts.height
    local gap = UI.sz(GAP)
    local half = math.max(1, math.floor((w - gap) / 2))
    local y = opts.y or 0
    local col_opts = { width = half, height = h, y = y, budget = h, desktop = ctx.desktop }
    local weather_part = self.weather:build(ctx, col_opts)
    local clock_part = self.clock:build(ctx, col_opts)
    local left, right
    if M.order() == ORDER_CLOCK then
        left, right = clock_part, weather_part
    else
        left, right = weather_part, clock_part
    end
    self.desktop = ctx.desktop
    self.region = Geom:new{ x = 0, y = y, w = w, h = h }
    return FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            dimen = Geom:new{ w = w, h = h },
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = h },
                HorizontalGroup:new{
                    align = "center",
                    left,
                    HorizontalSpan:new{ width = gap },
                    right,
                },
            },
        }
end

--- 启动两个子视图的数据加载，待两者结束后汇总成功或失败。
---@param cb fun(ok:boolean, err:any)|nil 全部子视图加载完成后的结果回调
---@return nil
function M:onStart(cb)
    ensureKids(self)
    local remaining, failure = 2, nil
    --- 记录一个子任务结束，所有子任务完成后通知调用者。
    ---@param ok boolean 本次操作是否成功
    ---@param err any 操作失败的原因
    ---@return nil
    local function done(ok, err)
        if not ok then failure = failure or err end
        remaining = remaining - 1
        if remaining == 0 and cb then cb(failure == nil, failure) end
    end
    self.clock:onStart(done)
    self.weather:onStart(done)
end

--- 恢复时钟与天气子视图的显示及周期工作。
---@return nil
function M:onResume()
    ensureKids(self)
    if self.clock then self.clock:onResume() end
    if self.weather then self.weather:onResume() end
end

--- 暂停两个子视图的周期工作和在飞请求。
---@return nil
function M:onPause()
    if self.clock then self.clock:onPause() end
    if self.weather then self.weather:onPause() end
end

--- 把停止阶段传递给时钟和天气子视图。
---@return nil
function M:onStop()
    if self.clock then self.clock:onStop() end
    if self.weather then self.weather:onStop() end
end

--- 销毁两个子视图并清除父视图保存的引用。
---@return nil
function M:onDestroy()
    if self.clock then self.clock:onDestroy() end
    if self.weather then self.weather:onDestroy() end
    self.clock = nil
    self.weather = nil
    self.region = nil
    self.desktop = nil
end

return M
