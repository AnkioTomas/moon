--[[--
主体：时钟。布局跟天气同构：居中大时间 + 下方两行辅文（日期 / 农历节日）。

@module koplugin.book.ui.desktop.home.views.clock
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local Myrl = require("online.myrl")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local GAP = 4
local SUB_H = 18
local DOW = { _("日"), _("一"), _("二"), _("三"), _("四"), _("五"), _("六") }

---@class BookHomeClock : BookHomeComponent
---@field desktop BookDesktop|nil
---@field region table|nil
---@field time_widget table|nil
---@field detail table|nil
---@field extra table|nil
---@field lunar string|nil
---@field holiday string|nil
---@field _tick fun()|nil
local M = {
    id = "clock",
    label = _("时钟"),
    icon = "schedule",
}
setmetatable(M, require("ui.desktop.home.views.base"))
M.__index = M

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

--- 组合当前日期与本地化星期文案。
---@return string
local function dateLine()
    return os.date("%Y-%m-%d") .. " " .. _("星期")
        .. DOW[(tonumber(os.date("%w")) or 0) + 1]
end

--- 组合农历与节日名称；两项均缺失时显示占位符。
---@param lunar string|nil 农历日期文字
---@param holiday string|nil 节日名称文字
---@return string
local function lunarLine(lunar, holiday)
    local parts = {}
    if type(lunar) == "string" and lunar ~= "" then
        parts[#parts + 1] = lunar
    end
    if type(holiday) == "string" and holiday ~= "" then
        parts[#parts + 1] = holiday
    end
    return #parts > 0 and table.concat(parts, " · ") or "--"
end

--- 取消本实例保存的定时回调并清除句柄。
---@param self BookHomeClock 当前视图或布局实例
---@return nil
local function stopTick(self)
    if self._tick then UIManager:unschedule(self._tick) end
    self._tick = nil
end

--- 按指定宽高构建时间、日期和农历节日三行内容。
---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    if self.data then self.lunar, self.holiday = self.data.lunar, self.data.holiday end
    local w = opts.width
    local total_h = opts.height
    local gap = UI.sz(GAP)
    local sub_h = math.min(UI.sz(SUB_H), math.max(1, math.floor((total_h - UI.sz(36) - gap * 2) / 2)))
    local time_h = math.max(1, total_h - sub_h * 2 - gap * 2)
    local y = opts.y or 0
    local max_w = math.max(1, w - UI.sz(20))
    self.time_widget = TextWidget:new{
        text = os.date("%H:%M"),
        face = UI.face("cfont", 36),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    self.detail = TextWidget:new{
        text = dateLine(),
        face = UI.face("xx_smallinfofont", 13),
        max_width = max_w,
        fgcolor = UI.muted(),
    }
    self.extra = TextWidget:new{
        text = lunarLine(self.lunar, self.holiday),
        face = UI.face("xx_smallinfofont", 12),
        max_width = max_w,
        fgcolor = UI.dim(),
    }
    self.desktop = ctx.desktop
    self.region = Geom:new{ x = 0, y = y, w = w, h = total_h }
    return FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            dimen = Geom:new{ w = w, h = total_h },
            VerticalGroup:new{
                align = "center",
                CenterContainer:new{
                    dimen = Geom:new{ w = w, h = time_h },
                    self.time_widget,
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
        }
end

--- 更新当前时间、日期及农历节日文字，并请求内容区域刷新。
---@return nil
function M:paint()
    if not self.time_widget then return end
    self.time_widget:setText(os.date("%H:%M"))
    if self.detail then self.detail:setText(dateLine()) end
    if self.extra then self.extra:setText(lunarLine(self.lunar, self.holiday)) end
    self:dirty("content")
end

--- 取消旧计时回调，立即刷新一次后按下一分钟边界继续调度。
---@return nil
function M:tick()
    if not self.time_widget then return end
    stopTick(self)
    self._tick = function()
        if not self.lifecycle:uiReady() then return end
        self:paint()
        UIManager:scheduleIn(61 - tonumber(os.date("%S")), self._tick)
    end
    self._tick()
end

--- 异步读取日报中的农历和节日数据，失败时保留原数据。
---@param done fun(data:any, err:any) 数据加载回调；失败回退旧数据时仍按成功交付
---@return table|nil request 在线接口返回的取消句柄；同步缓存命中可能无句柄
function M:loadData(done)
    return Myrl:fetch({}, function(data, err)
        done(not err and data or self.data)
    end)
end

--- 仅在 Resume 阶段发起数据加载；数据变化后更新内容，取消的旧回调不再改写视图。
---@return nil
function M:pull()
    if not self.lifecycle:uiReady() then return end
    local previous = self.data
    self:load(function(ok)
        if ok and self.data ~= previous then
            self.lunar = self.data and self.data.lunar
            self.holiday = self.data and self.data.holiday
            self:paint()
        end
    end)
end

--- 刷新时间文字，启动分钟计时器并拉取农历节日。
---@return nil
function M:onResume()
    self:paint()
    self:tick()
    self:pull()
end

--- 取消分钟计时器，保留已有显示数据。
---@return nil
function M:onPause()
    stopTick(self)
end

--- 取消计时器并清除文字控件及桌面引用。
---@return nil
function M:onDestroy()
    stopTick(self)
    self.time_widget = nil
    self.detail = nil
    self.extra = nil
    self.region = nil
    self.desktop = nil
end

return M
