--[[--
主体：天气。布局跟时钟同构：居中大温度 + 下方两行辅文；自己拉网，成功才刷。

@module koplugin.book.ui.desktop.home.components.weather
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Image = require("ui.components.image")
local MoonSettings = require("utils.settings")
local OnlineWeather = require("online.weather")
local Text = require("utils.text")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template

local INTERVAL = 3600
local PICTURE = 36
local GAP = 4
local SUB_H = 18
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
setmetatable(M, require("ui.desktop.home.components.base"))
M.__index = M

function M:heightRange()
    return {
        min = UI.sz(80),
        preferred = UI.sz(96),
        max = UI.sz(120),
        grow = 0,
    }
end

--- 辅文第一行：天气 · 地点 · 温差。
---@param wx BookWeather
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
---@param wx BookWeather
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
---@param wx BookWeather|nil
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
---@param wx BookWeather|nil
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

---@param self BookHomeWeather
local function dropPicture(self)
    if self.picture and self.picture.cancel then
        self.picture:cancel()
    end
    self.picture = nil
end

--- 主行左侧图标；同一 URL 不换框。
---@param self BookHomeWeather
---@param desktop table|nil
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

---@param self BookHomeWeather
---@param desktop table|nil
---@return table
local function putHero(self, desktop)
    local icon = mark(self, desktop)
    local hero = self.hero
    if not hero then
        hero = HorizontalGroup:new{ align = "center" }
        self.hero = hero
    end
    hero[1], hero[2], hero[3] = icon, HorizontalSpan:new{ width = UI.sz(8) }, self.temp
    return hero
end

---@param self BookHomeWeather
local function stopTick(self)
    if self._tick then UIManager:unschedule(self._tick) end
    self._tick = nil
end

---@param ctx BookDesktopCtx
---@param opts BookHomeBuildOpts
---@return table
function M:build(ctx, opts)
    dropPicture(self)
    local w = opts.width
    local total_h = opts.height
    local gap = UI.sz(GAP)
    local sub_h = math.min(UI.sz(SUB_H), math.max(1, math.floor((total_h - UI.sz(36) - gap * 2) / 2)))
    local temp_h = math.max(1, total_h - sub_h * 2 - gap * 2)
    local y = opts.y or 0
    local temp, detail, extra = texts(self.wx)
    local max_w = math.max(1, w - UI.sz(20))
    self.temp = TextWidget:new{
        text = temp,
        face = UI.face("cfont", 36),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    self.detail = TextWidget:new{
        text = detail,
        face = UI.face("xx_smallinfofont", 13),
        max_width = max_w,
        fgcolor = UI.muted(),
    }
    self.extra = TextWidget:new{
        text = extra,
        face = UI.face("xx_smallinfofont", 12),
        max_width = max_w,
        fgcolor = UI.dim(),
    }
    local hero = putHero(self, ctx.desktop)
    self.desktop = ctx.desktop
    self.region = Geom:new{ x = 0, y = y, w = w, h = total_h }
    if self:uiReady() then
        self:pull()
        self:scheduleHourly()
    end
    return {
        height = total_h,
        widget = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            dimen = Geom:new{ w = w, h = total_h },
            VerticalGroup:new{
                align = "center",
                CenterContainer:new{
                    dimen = Geom:new{ w = w, h = temp_h },
                    hero,
                },
                VerticalSpan:new{ width = gap },
                CenterContainer:new{
                    dimen = Geom:new{ w = w, h = sub_h },
                    self.detail,
                },
                VerticalSpan:new{ width = gap },
                CenterContainer:new{
                    dimen = Geom:new{ w = w, h = sub_h },
                    self.extra,
                },
            },
        },
    }
end

function M:paint()
    if not self.temp then return end
    local temp, detail, extra = texts(self.wx)
    self.temp:setText(temp)
    self.detail:setText(detail)
    self.extra:setText(extra)
    putHero(self, self.desktop)
    UIManager:setDirty(self.desktop, "ui", self.region)
end

function M:pull()
    if not self:uiReady() or not self.temp then return end
    self:addHttp(OnlineWeather:fetch({
        city = Text.trim(MoonSettings.get("home").home_weather_city),
    }, function(data, err)
        if not self:uiReady() then return end
        if err or not data.temp then return end
        self.wx = data
        self:paint()
    end))
end

function M:scheduleHourly()
    stopTick(self)
    if not self:uiReady() then return end
    self._tick = function()
        if not self:uiReady() then return end
        self:pull()
        self:scheduleHourly()
    end
    UIManager:scheduleIn(INTERVAL, self._tick)
end

function M:onResume()
    self:paint()
    self:pull()
    self:scheduleHourly()
end

function M:onPause()
    stopTick(self)
    dropPicture(self)
end

function M:onDestroy()
    self.hero = nil
    self.temp = nil
    self.detail = nil
    self.extra = nil
    self.region = nil
    self.desktop = nil
end

return M
