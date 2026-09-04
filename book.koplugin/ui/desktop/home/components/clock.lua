--[[--
主体：时钟。

@module koplugin.book.ui.desktop.home.components.clock
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local M = {
    id = "clock",
    label = _("时钟"),
    icon = "schedule",
}

local DOW = { _("日"), _("一"), _("二"), _("三"), _("四"), _("五"), _("六") }

function M.heightRange()
    return {
        min = UI.sz(64),
        preferred = UI.sz(76),
        max = UI.sz(104),
        grow = 1,
    }
end

---@param ctx table
---@param _state table
---@param opts table
---@return table
function M.build(ctx, _state, opts)
    local w = opts.width
    local total_h = opts.height
    local time_widget = TextWidget:new{
        text = os.date("%H:%M"),
        face = UI.face("cfont", 36),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local date_widget = TextWidget:new{
        text = os.date("%Y-%m-%d") .. " " .. _("星期")
            .. DOW[(tonumber(os.date("%w")) or 0) + 1],
        face = UI.face("xx_smallinfofont", 13),
        fgcolor = UI.muted(),
    }
    local body = CenterContainer:new{
        dimen = Geom:new{ w = w, h = total_h },
        VerticalGroup:new{
            align = "center",
            time_widget,
            VerticalSpan:new{ width = UI.sz(4) },
            date_widget,
        },
    }
    local widget = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        dimen = Geom:new{ w = w, h = total_h },
        body,
    }
    return {
        widget = widget,
        height = total_h,
        refresh = function()
            time_widget:setText(os.date("%H:%M"))
            date_widget:setText(os.date("%Y-%m-%d") .. " " .. _("星期")
                .. DOW[(tonumber(os.date("%w")) or 0) + 1])
        end,
    }
end

return M
