--[[--
主体：时钟。时间自己跳；下面的日历自己拉网、自己刷新。

@module koplugin.book.ui.desktop.home.components.clock
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Calendar = require("ui.desktop.home.components.clock.calendar")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

---@class BookHomeClock : BookHomeComponent
---@field desktop BookDesktop|nil
---@field region table|nil
---@field time_widget table|nil
---@field calendar BookHomeCalendar|nil
---@field _tick fun()|nil
local M = {
    id = "clock",
    label = _("时钟"),
    icon = "schedule",
}
setmetatable(M, require("ui.desktop.home.components.base"))
M.__index = M

local GAP = 4
local CAL_H = 20

function M:heightRange()
    return {
        min = UI.sz(64),
        preferred = UI.sz(76),
        max = UI.sz(104),
        grow = 1,
    }
end

---@param self BookHomeClock
---@return BookHomeCalendar
local function calendar(self)
    if not self.calendar then
        self.calendar = Calendar:new()
    end
    self.calendar.home = self.home
    return self.calendar
end

---@param ctx BookDesktopCtx
---@param opts BookHomeBuildOpts
---@return table
function M:build(ctx, opts)
    local w = opts.width
    local total_h = opts.height
    local gap = UI.sz(GAP)
    local cal_h = math.min(UI.sz(CAL_H), math.max(1, total_h - UI.sz(36)))
    local time_h = math.max(1, total_h - cal_h - gap)
    local y = opts.y or 0
    local time_widget = TextWidget:new{
        text = os.date("%H:%M"),
        face = UI.face("cfont", 36),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local cal = calendar(self):build(ctx, {
        width = w,
        height = cal_h,
        y = y + time_h + gap,
    })
    local widget = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        dimen = Geom:new{ w = w, h = total_h },
        VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = time_h },
                time_widget,
            },
            VerticalSpan:new{ width = gap },
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = cal_h },
                cal.widget,
            },
        },
    }
    self.desktop = ctx.desktop
    self.region = Geom:new{ x = 0, y = y, w = w, h = time_h }
    self.time_widget = time_widget
    if self:uiReady() then self:updateView() end
    return { widget = widget, height = total_h }
end

function M:updateView()
    if not self.time_widget then return end
    if self._tick then UIManager:unschedule(self._tick) end
    self._tick = function()
        self.time_widget:setText(os.date("%H:%M"))
        UIManager:setDirty(self.desktop, "ui", self.region)
        UIManager:scheduleIn(61 - tonumber(os.date("%S")), self._tick)
    end
    self._tick()
end

function M:onResume()
    calendar(self):onResume()
    self:updateView()
end

function M:onPause()
    if self._tick then UIManager:unschedule(self._tick) end
    self._tick = nil
    calendar(self):onPause()
end

function M:onStop()
    calendar(self):onStop()
end

function M:onDestroy()
    calendar(self):onDestroy()
    self.time_widget = nil
    self.region = nil
    self.desktop = nil
end

return M
