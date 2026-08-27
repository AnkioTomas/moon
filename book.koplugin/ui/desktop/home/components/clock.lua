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

---@param ctx table
---@param _state table
---@param opts table
---@return table
function M.build(ctx, _state, opts)
    local w = opts.width
    local pad_y = UI.sz(10)
    local body_h = UI.sz(56)
    local total_h = body_h + pad_y * 2
    local time_text = os.date("%H:%M")
    local wday = tonumber(os.date("%w")) or 0
    local date_text = os.date("%Y-%m-%d") .. " " .. _("星期") .. DOW[wday + 1]
    local body = CenterContainer:new{
        dimen = Geom:new{ w = w, h = body_h },
        VerticalGroup:new{
            align = "center",
            TextWidget:new{
                text = time_text,
                face = UI.face("cfont", 36),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
            VerticalSpan:new{ width = UI.sz(4) },
            TextWidget:new{
                text = date_text,
                face = UI.face("xx_smallinfofont", 13),
                fgcolor = UI.muted(),
            },
        },
    }
    local widget = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        padding_top = pad_y,
        padding_bottom = pad_y,
        margin = 0,
        dimen = Geom:new{ w = w, h = total_h },
        body,
    }
    return { widget = widget, height = total_h }
end

return M
