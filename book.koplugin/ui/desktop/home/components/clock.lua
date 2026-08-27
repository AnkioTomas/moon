--[[--
主体：时钟。

@module koplugin.book.ui.desktop.home.components.clock
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local M = {
    id = "clock",
    label = _("时钟"),
}

local function clockHeight()
    return UI.sz(72)
end

---@param ctx table
---@param _state table
---@param opts table
---@return table
function M.build(ctx, _state, opts)
    local w = opts.width
    local h = clockHeight()
    local time_text = os.date("%H:%M")
    local date_text = os.date("%Y-%m-%d %A")
    local widget = CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
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
    return { widget = widget, height = h }
end

return M
