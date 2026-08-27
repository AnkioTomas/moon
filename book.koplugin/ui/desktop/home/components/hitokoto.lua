--[[--
主体：一言（引号 + 左文右出处，无卡片）。

@module koplugin.book.ui.desktop.home.components.hitokoto
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local MoonSettings = require("utils.settings")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local U = require("lockscreen.components.util")
local _ = require("gettext")

local M = {
    id = "hitokoto",
    label = _("一言"),
    icon = "format_quote",
}

---@param ctx table
---@param state table
---@param opts table
---@return table
function M.build(ctx, state, opts)
    local w = opts.width
    local pad_x = UI.sz(10)
    local pad_y = UI.sz(6)
    local inner_w = math.max(1, w - pad_x * 2)
    local quote = state.quote or {}
    local text = quote.text or MoonSettings.get().lock_screen_quote_cache or U.FALLBACK_MESSAGE
    local source = quote.source or MoonSettings.get().lock_screen_quote_source_cache or _("一言")

    local mark_w = TextWidget:new{
        text = "“",
        face = UI.face("cfont", 28),
        fgcolor = UI.dim(),
    }
    local body_w = TextWidget:new{
        text = text,
        face = UI.face("cfont", 15),
        max_width = inner_w,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local rule_h = 1
    local rule = LineWidget:new{
        background = Blitbuffer.COLOR_GRAY_5,
        dimen = Geom:new{ w = inner_w, h = rule_h },
    }
    local src_w = TextWidget:new{
        text = source,
        face = UI.face("xx_smallinfofont", 12),
        max_width = inner_w,
        fgcolor = UI.muted(),
    }
    local src_h = src_w:getSize().h
    local inner_h = mark_w:getSize().h + UI.sz(4) + body_w:getSize().h + UI.sz(8)
        + rule_h + UI.sz(6) + src_h
    local content = VerticalGroup:new{
        align = "left",
        mark_w,
        VerticalSpan:new{ width = UI.sz(4) },
        body_w,
        VerticalSpan:new{ width = UI.sz(8) },
        rule,
        VerticalSpan:new{ width = UI.sz(6) },
        RightContainer:new{
            dimen = Geom:new{ w = inner_w, h = src_h },
            src_w,
        },
    }
    local total_h = inner_h + pad_y * 2
    local widget = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        padding_left = pad_x,
        padding_right = pad_x,
        padding_top = pad_y,
        padding_bottom = pad_y,
        margin = 0,
        dimen = Geom:new{ w = w, h = total_h },
        LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            content,
        },
    }
    return { widget = widget, height = total_h }
end

return M
