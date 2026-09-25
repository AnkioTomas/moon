--[[--
主体：天气。布局跟时钟同构：居中大温度 + 下方两行辅文；自己拉网，成功才刷。

@module koplugin.book.ui.desktop.home.views.weather
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Clock = require("ui.desktop.home.views.clock")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Image = require("ui.components.image")
local MoonSettings = require("utils.settings")
local OnlineWeather = require("online.weather")
local Text = require("utils.text")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local UIManager = require("ui/uimanager")
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
---@field desktop BookDesktop|nil
---@field region table|nil
---@field _tick fun()|nil
local M = {
    id = "weather",
    label = _("天气"),
    icon = "partly_cloudy_day",
}
setmetatable(M, require("ui.desktop.home.views.base"))
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
    if self.picture and self.picture.cancel then
        self.picture:cancel()
    end
    self.picture = nil
end

--- 主行左侧图标；同一 URL 不换框。
---@param self BookHomeWeather 当前视图或布局实例
---@param desktop table|nil 所属桌面实例
---@return table
local function mark(self, desktop)
    local src = imageSrc(self.wx)
    if self.picture and self.picture.src == src then
        return self.picture
    end
    dropPicture(self)
    self.picture = Image.widget{
        src = src,
        width = UI.sz(PICTURE),
        height = UI.sz(PICTURE),
        show_parent = desktop,
    }
    self.picture.src = src
    return self.picture
end

--- 替换主天气行的图标并复用温度文字；释放旧图标后重置行布局缓存。
---@param self BookHomeWeather 当前视图或布局实例
---@param desktop table|nil 所属桌面实例
---@return table
local function putHero(self, desktop)
    local icon = mark(self, desktop)
    local hero = self.hero
    if not hero then
        hero = HorizontalGroup:new{ align = "center" }
        self.hero = hero
    end
    local previous = hero[1]
    hero[1], hero[2], hero[3] = icon, hero[2] or HorizontalSpan:new{ width = UI.sz(8) }, self.temp
    if previous and previous ~= icon and previous.free then previous:free() end
    if hero.resetLayout then hero:resetLayout() end
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
    self.wx = self.data or self.wx
    dropPicture(self)
    self.hero = nil
    local temp, detail, extra = texts(self.wx)
    self.temp = TextWidget:new{
        text = temp,
        face = UI.face("cfont", 36),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    return Clock.stack(self, putHero(self, self.ctx.desktop), detail, extra)
end

--- 将最新天气写入已有文字和图标行，然后刷新内容区域。
function M:paint()
    if not self.temp then return end
    local temp, detail, extra = texts(self.wx)
    self.temp:setText(temp)
    self.detail:setText(detail)
    self.extra:setText(extra)
    putHero(self, self.desktop)
    self:dirty("content")
end

--- 按设置的城市异步取得天气；失败或缺少温度时保留旧天气。
---@param done fun(data:any, err:any) 数据加载回调；失败回退旧数据时仍按成功交付
---@return table|nil request 在线接口返回的取消句柄；同步缓存命中可能无句柄
function M:loadData(done)
    return OnlineWeather:fetch({
        city = Text.trim(MoonSettings.get("home").home_weather_city),
    }, function(data, err)
        done(not err and data and data.temp and data or self.wx)
    end)
end

--- 仅在 Resume 阶段发起数据加载；数据变化后更新内容，取消的旧回调不再改写视图。
function M:pull()
    if not self.lifecycle:uiReady() then return end
    local previous = self.data
    self:load(function(ok)
        if ok and self.data ~= previous then
            self.wx = self.data
            self:paint()
        end
    end)
end

--- 取消旧定时器并安排下一次天气拉取，只在 Resume 阶段续订。
function M:scheduleHourly()
    stopTick(self)
    if not self.lifecycle:uiReady() then return end
    self._tick = function()
        if not self.lifecycle:uiReady() then return end
        self:pull()
        self:scheduleHourly()
    end
    UIManager:scheduleIn(INTERVAL, self._tick)
end

--- 换源或首页刷新后重建，并按当前地点重拉天气。
---@param event string
function M:onEvent(event)
    require("ui.desktop.home.views.base").onEvent(self, event)
    if event == "home_refresh" or event == "source_changed" then
        self:pull()
    end
end

--- 绘制已有天气，立即拉取新数据并启动周期刷新。
function M:onResume()
    self:paint()
    self:pull()
    self:scheduleHourly()
end

--- 取消天气定时器和图标请求。
function M:onPause()
    stopTick(self)
    dropPicture(self)
end

--- 清除天气图标行、文字控件及桌面引用。
function M:onDestroy()
    self.hero = nil
    self.temp = nil
    self.detail = nil
    self.extra = nil
    self.region = nil
    self.desktop = nil
end

--- 地名必须是英文字母（接口不吃中文）；不合规时提示并返回 true。
---@param city string
---@return boolean
local function rejectPlace(city)
    if city == "" or city:find("[A-Za-z]") then return false end
    UIManager:show(require("ui/widget/infomessage"):new{
        text = _("请用英文字母填写地名，例如 Shanghai"),
        timeout = 3,
    })
    return true
end

--- 编辑态设置：天气地点输入框。
---@param desktop table|nil
function M:showSettings(desktop)
    desktop = desktop or self.desktop or (self.home and self.home.desktop)
    local InfoMessage = require("ui/widget/infomessage")
    local InputDialog = require("ui/widget/inputdialog")
    local home = MoonSettings.get("home")
    local testing = false
    local dialog
    local function probe()
        if testing then return end
        local city = Text.trim(dialog:getInputText())
        if rejectPlace(city) then return end
        testing = true
        local loading = InfoMessage:new{ text = _("正在测试…") }
        UIManager:show(loading)
        OnlineWeather:fetch({ city = city, ttl = 0 }, function(wx)
            testing = false
            UIManager:close(loading)
            if desktop and desktop.lifecycle and desktop.lifecycle.state == "Destroy" then return end
            if wx.temp then
                local place = wx.city or (city == "" and _("当前 IP") or city)
                local text = place .. " · " .. wx.temp .. "°"
                if wx.desc then
                    text = text .. " · " .. wx.desc
                end
                UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
            else
                UIManager:show(InfoMessage:new{
                    text = T(_("测试失败：%1"), _("没有查到天气")),
                    timeout = 4,
                })
            end
        end)
    end
    dialog = InputDialog:new{
        title = _("天气地点"),
        input = tostring(home.home_weather_city or ""),
        input_hint = "Shanghai",
        description = _("留空按 IP 定位。填写请用英文字母，例如 Shanghai。"),
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("测试"),
                callback = probe,
            },
            {
                text = _("保存"),
                is_enter_default = true,
                callback = function()
                    local city = Text.trim(dialog:getInputText())
                    if rejectPlace(city) then return end
                    home.home_weather_city = city
                    MoonSettings.saveSection("home", home)
                    UIManager:close(dialog)
                    if desktop and desktop.onEvent then desktop:onEvent("home_refresh") end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return M
