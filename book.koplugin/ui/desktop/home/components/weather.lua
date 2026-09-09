--[[--
主体：天气。自己拉 online.weather；成功才刷自己那一块，失败停在默认。

@module koplugin.book.ui.desktop.home.components.weather
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Icon = require("ui.components.icon")
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
local PICTURE = 40
local FALLBACK_ICON = "partly_cloudy_day"

---@class BookHomeWeather : BookHomeComponent
---@field wx BookWeather|nil
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
        min = UI.sz(56),
        preferred = UI.sz(72),
        max = UI.sz(96),
        grow = 1,
    }
end

---@return string
local function city()
    return Text.trim(MoonSettings.get("home").home_weather_city)
end

---@param wx BookWeather|nil
---@return string
---@return string
---@return string
---@return string|nil
local function texts(wx)
    wx = wx or {}
    if not wx.temp then
        return _("天气"), _("暂无数据"), FALLBACK_ICON, nil
    end
    local detail = wx.desc or _("天气")
    if wx.city then
        detail = detail .. " · " .. wx.city
    end
    if wx.low and wx.high then
        detail = detail .. " · " .. wx.low .. "–" .. wx.high .. "°"
    elseif wx.feels then
        detail = detail .. " · " .. T(_("体感 %1°"), wx.feels)
    end
    if wx.humidity then
        detail = detail .. " · " .. T(_("湿度 %1"), wx.humidity) .. "%"
    end
    return wx.temp .. "°", detail, wx.icon or FALLBACK_ICON, wx.image
end

---@param self BookHomeWeather
local function dropPicture(self)
    if self.picture and self.picture.cancel then
        self.picture:cancel()
    end
    self.picture = nil
    self.image_src = nil
end

---@param self BookHomeWeather
---@param src string|nil
---@param icon_name string
---@param desktop table|nil
---@return table
local function badge(self, src, icon_name, desktop)
    if src and src ~= "" then
        if self.image_src == src and self.picture then
            return self.picture
        end
        dropPicture(self)
        self.image_src = src
        self.picture = Image.widget{
            src = src,
            width = UI.sz(PICTURE),
            height = UI.sz(PICTURE),
            alpha = true,
            show_parent = desktop,
        }
        return self.picture
    end
    dropPicture(self)
    return Icon.widget{ name = icon_name, size = 36 }
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
    local temp, detail, icon_name, image = texts(self.wx)
    local temp_w = TextWidget:new{
        text = temp,
        face = UI.face("cfont", 28),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local detail_w = TextWidget:new{
        text = detail,
        face = UI.face("xx_smallinfofont", 13),
        max_width = math.max(1, w - UI.sz(20)),
        fgcolor = UI.muted(),
    }
    local head = HorizontalGroup:new{
        align = "center",
        badge(self, image, icon_name, ctx.desktop),
        HorizontalSpan:new{ width = UI.sz(8) },
        temp_w,
    }
    local widget = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        dimen = Geom:new{ w = w, h = total_h },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = total_h },
            VerticalGroup:new{
                align = "center",
                head,
                VerticalSpan:new{ width = UI.sz(4) },
                detail_w,
            },
        },
    }
    self.head = head
    self.temp = temp_w
    self.detail = detail_w
    self.desktop = ctx.desktop
    self.region = Geom:new{ x = 0, y = opts.y or 0, w = w, h = total_h }
    if self:uiReady() then
        self:pull()
        self:scheduleHourly()
    end
    return { widget = widget, height = total_h }
end

function M:paint(dirty)
    if not self.temp then return end
    local temp, detail, icon_name, image = texts(self.wx)
    self.temp:setText(temp)
    self.detail:setText(detail)
    self.head[1] = badge(self, image, icon_name, self.desktop)
    if dirty then
        UIManager:setDirty(self.desktop, "ui", self.region)
    end
end

function M:pull()
    if not self:uiReady() or not self.temp then return end
    self:addHttp(OnlineWeather:fetch({ city = city() }, function(data, err)
        if not self:uiReady() then return end
        if err or not data.temp then return end
        self.wx = data
        self:paint(true)
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
    self:paint(true)
    self:pull()
    self:scheduleHourly()
end

function M:onPause()
    stopTick(self)
    dropPicture(self)
end

function M:onDestroy()
    stopTick(self)
    dropPicture(self)
    self.head = nil
    self.temp = nil
    self.detail = nil
    self.region = nil
    self.desktop = nil
end

return M
