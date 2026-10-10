--[[--
主体：天气。布局跟时钟同构：居中大温度 + 下方两行辅文；读 online.weather，成功才刷。

@module koplugin.book.desktop.pages.home.weather
--]]

local Clock = require("desktop.pages.home.clock")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local MoonSettings = require("utils.settings")
local OnlineWeather = require("online.weather")
local Text = require("utils.text")
local UIManager = require("ui/uimanager")
local Theme = require("ui.themes")
local Image = require("ui.themes.widgets.image")
local ThemeText = require("ui.themes.widgets.text")
local Toast = require("ui.themes.widgets.toast")
local _ = require("gettext")
local T = require("ffi/util").template

local INTERVAL = 3600
local PICTURE = 36
--- 空态占位：多云图，比 unknown 看着不像出错。
local EMPTY_ICON = "cloud"

---@class BookHomeWeather : BookHomeComponent
---@field wx BookWeather|nil
---@field picture table|nil
---@field hero table|nil
---@field temp table|nil
---@field detail table|nil
---@field extra table|nil
---@field _tick fun()|nil
local M = {
    id = "weather",
    label = _("天气"),
    icon = "partly_cloudy_day",
}
setmetatable(M, require("desktop.pages.home.base"))
M.__index = M

--- 返回天气内容高度；温度 + 两行辅文，与时钟同构，不吃剩余空间。
---@return BookHomeHeightSpec
function M:heightRange()
    return { height = Clock.contentHeight() }
end

--- 辅文第一行：天气 · 地点 · 温差。
---@param wx BookWeather 天气接口返回的数据
---@return string
local function summary(wx)
    local parts = {}
    if wx.desc and wx.desc ~= "" then parts[#parts + 1] = wx.desc end
    if wx.city and wx.city ~= "" then parts[#parts + 1] = wx.city end
    if wx.low and wx.high then
        parts[#parts + 1] = wx.low .. "–" .. wx.high .. "°"
    end
    return #parts > 0 and table.concat(parts, " · ") or "--"
end

--- 辅文第二行：体感 / 湿度 / 风向风速；都没有就日出日落。
---@param wx BookWeather 天气接口返回的数据
---@return string
local function metrics(wx)
    local parts = {}
    if wx.feels then
        parts[#parts + 1] = T(_("体感 %1°"), wx.feels)
    end
    if wx.humidity then
        parts[#parts + 1] = T(_("湿度 %1%"), wx.humidity)
    end
    if wx.wind and wx.wind_kmph then
        parts[#parts + 1] = T(_("%1风 %2km/h"), wx.wind, wx.wind_kmph)
    elseif wx.wind then
        parts[#parts + 1] = wx.wind .. _("风")
    elseif wx.wind_kmph then
        parts[#parts + 1] = wx.wind_kmph .. "km/h"
    end
    if #parts == 0 and wx.sunrise and wx.sunset then
        parts[1] = T(_("日出 %1"), wx.sunrise)
        parts[2] = T(_("日落 %1"), wx.sunset)
    end
    return #parts > 0 and table.concat(parts, " · ") or "--"
end

--- 大温度 + 两行辅文。空态也带 °，主行始终有图标。
---@param wx BookWeather|nil 天气接口返回的数据
---@return string
---@return string
---@return string
local function texts(wx)
    wx = wx or {}
    if not wx.temp then
        return "--°", "--", "--"
    end
    return wx.temp .. "°", summary(wx), metrics(wx)
end

--- 有天气用接口图（或按 icon 键回退）；空态用多云占位。
---@param wx BookWeather|nil 天气接口返回的数据
---@return string
local function imageSrc(wx)
    if wx and wx.temp then
        if type(wx.image) == "string" and wx.image ~= "" then
            return wx.image
        end
        return OnlineWeather.iconUrl(wx.icon or "unknown")
    end
    return OnlineWeather.iconUrl(EMPTY_ICON)
end

--- 取消当前天气图标的在飞请求并清除图标引用。
---@param self BookHomeWeather 当前视图或布局实例
local function dropPicture(self)
    if self.picture then self.picture[1]:cancel() end
    self.picture = nil
end

--- 主行左侧图标；同一 URL 不换框。
---@param self BookHomeWeather 当前视图或布局实例
---@return table
local function mark(self)
    local src = imageSrc(self.wx)
    if self.picture and self.picture.src == src then
        return self.picture
    end
    dropPicture(self)
    local size = Theme.px(PICTURE)
    self.picture = Image.widget{ src = src, width = size, height = size, style = {} }
    self.picture.src = src
    return self.picture
end

--- 替换主天气行的图标并复用温度文字；释放旧图标后重置行布局缓存。
---@param self BookHomeWeather 当前视图或布局实例
---@return table
local function putHero(self)
    local icon = mark(self)
    local hero = self.hero
    if not hero then
        hero = HorizontalGroup:new{ align = "center" }
        self.hero = hero
    end
    local previous = hero[1]
    hero[1], hero[2], hero[3] = icon, hero[2] or HorizontalSpan:new{ width = Theme.px(Theme.current().space.sm) }, self.temp
    if previous and previous ~= icon then previous:free() end
    hero:resetLayout()
    return hero
end

--- 取消本实例保存的定时回调并清除句柄。
---@param self BookHomeWeather 当前视图或布局实例
local function stopTick(self)
    if self._tick then UIManager:unschedule(self._tick) end
    self._tick = nil
end

--- 构建主天气图标、温度和辅助信息行，旧图标请求先取消。
---@return table
function M:createWidget()
    dropPicture(self)
    self.hero = nil
    local temp, detail, extra = texts(self.wx)
    self.temp = ThemeText.line("hero", temp)
    return Clock.stack(self, putHero(self), detail, extra)
end

--- 将最新天气写入已有文字和图标行；文字和图标都未变时不刷新。
function M:paint()
    if not self.temp then return end
    local temp, detail, extra = texts(self.wx)
    if self.temp.text == temp and self.detail.text == detail and self.extra.text == extra
        and self.picture and self.picture.src == imageSrc(self.wx) then
        return
    end
    self.temp:setText(temp)
    self.detail:setText(detail)
    self.extra:setText(extra)
    putHero(self)
    self:dirty()
end

--- 按当前设置写地点后 ensure；未过期不拉网，换地点才拆掉重拉。
function M:bindCity()
    OnlineWeather.city = Text.trim(MoonSettings.get("desktop.pages.home").home_weather_city)
end

--- 失败或缺温度保留旧天气；数据变化由 watch 回调重绘。
function M:pull()
    self:bindCity()
    OnlineWeather:ensure()
end

--- 取消旧定时器并安排下一次天气拉取，只在活跃时续订。
function M:scheduleHourly()
    stopTick(self)
    if not self.active then return end
    self._tick = function()
        if not self.active then return end
        self:pull()
        self:scheduleHourly()
    end
    UIManager:scheduleIn(INTERVAL, self._tick)
end

--- 首页刷新（改了地点）或换源后按当前地点重拉天气。
---@param event string
function M:onEvent(event)
    if event == "home_refresh" or event == "source_changed" then
        self:pull()
    end
end

--- 先画已有结果，再订阅；过期才入队。整点再 ensure 一次。
function M:onActivate()
    self:bindCity()
    self.wx = OnlineWeather:current()
    self:paint()
    self._on_wx = function(data, err)
        if err or not (data and data.temp) or data == self.wx then return end
        self.wx = data
        self:paint()
    end
    OnlineWeather:watch(self._on_wx)
    OnlineWeather:ensure()
    self:scheduleHourly()
end

--- 取消整点定时和图标请求；不取消 online 任务。
function M:onDeactivate()
    OnlineWeather:unwatch(self._on_wx)
    self._on_wx = nil
    stopTick(self)
    dropPicture(self)
end

--- 清除天气图标行和文字控件引用。
function M:onDestroy()
    self.hero = nil
    self.temp = nil
    self.detail = nil
    self.extra = nil
end

--- 地名必须是英文字母（接口不吃中文）；不合规时提示并返回 true。
---@param city string
---@return boolean
local function rejectPlace(city)
    if city == "" or city:find("[A-Za-z]") then return false end
    Toast:new{ text = _("请用英文字母填写地名，例如 Shanghai"), timeout = 3 }:show()
    return true
end

--- 试查一次天气并提示结果，不保存。
---@param city string
---@param desktop BookDesktop
---@param done fun() 查完（无论成败）
local function probe(city, desktop, done)
    local loading = Toast:new{ text = _("正在测试…") }
    loading:show()
    OnlineWeather:fetch({ city = city, ttl = 0 }, function(wx)
        done()
        loading:close()
        if desktop.closed then return end
        local text = T(_("测试失败：%1"), _("没有查到天气"))
        if wx and wx.temp then
            text = (wx.city or (city == "" and _("当前 IP") or city)) .. " · " .. wx.temp .. "°"
            if wx.desc then text = text .. " · " .. wx.desc end
        end
        Toast:new{ text = text, timeout = 4 }:show()
    end)
end

--- 编辑态设置：天气地点输入框。地名不合规时提示后带着原输入重开。
---@param desktop BookDesktop
---@param text string|nil 重开时保留的输入
function M:showSettings(desktop, text)
    local home = MoonSettings.get("desktop.pages.home")
    local testing = false
    require("ui.themes.widgets.input"):new{
        title = _("天气地点"),
        fields = { {
            label = _("留空按 IP 定位。填写请用英文字母，例如 Shanghai。"),
            text = text or home.home_weather_city or "",
            hint = "Shanghai",
        } },
        ok_text = _("保存"),
        actions = { { text = _("测试"), callback = function(raw)
            local city = Text.trim(raw)
            if testing or rejectPlace(city) then return end
            testing = true
            probe(city, desktop, function() testing = false end)
        end } },
        callback = function(raw)
            local city = Text.trim(raw)
            if rejectPlace(city) then
                self:showSettings(desktop, raw)
                return
            end
            home.home_weather_city = city
            MoonSettings.save("desktop.pages.home", home)
            desktop:onEvent("home_refresh")
        end,
    }:show()
end

return M
