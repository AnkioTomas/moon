--[[--
主体：书摘（最近一本的高亮轮换）。

@module koplugin.book.ui.desktop.home.components.excerpt
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextWidget = require("ui/widget/textwidget")
local Surface = require("ui.components.surface")
local UI = require("ui.components.bookui")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local U = require("lockscreen.components.util")
local _ = require("gettext")

local M = {
    id = "excerpt",
    label = _("书摘"),
    icon = "format_ink_highlighter",
}

---@param ctx table
---@param state table
---@param opts table
---@return table
function M.build(_ctx, state, opts)
    local w = opts.width
    local margin = UI.sz(10)
    local card_w = math.max(1, w - margin * 2)
    local pad = UI.sz(12)
    local inner_w = math.max(1, card_w - pad * 2)
    local excerpt = state.excerpt or {}
    local text = excerpt.text or U.FALLBACK_MESSAGE
    local source = excerpt.text and (excerpt.source or _("书摘")) or _("默认句子")
    local title_w = TextWidget:new{
        text = _("书摘"),
        face = UI.face("cfont", 12),
        bold = true,
        max_width = inner_w,
        fgcolor = UI.muted(),
    }
    local body = TextWidget:new{
        text = text,
        face = UI.face("cfont", 14),
        max_width = inner_w,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local src_w = TextWidget:new{
        text = source,
        face = UI.face("xx_smallinfofont", 11),
        max_width = inner_w,
        fgcolor = UI.dim(),
    }
    local inner_h = title_w:getSize().h + UI.sz(6) + body:getSize().h + UI.sz(6) + src_w:getSize().h
    local card_h = inner_h + pad * 2
    local content = VerticalGroup:new{
        align = "left",
        title_w,
        VerticalSpan:new{ width = UI.sz(6) },
        body,
        VerticalSpan:new{ width = UI.sz(6) },
        src_w,
    }
    local card = Surface.card(LeftContainer:new{
        dimen = Geom:new{ w = inner_w, h = inner_h },
        FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            content,
        },
    }, {
        width = card_w,
        height = card_h,
        padding = pad,
        shadow = true,
    })
    local widget = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        padding_left = margin,
        padding_right = margin,
        margin = 0,
        dimen = Geom:new{ w = w, h = card_h },
        card,
    }
    return { widget = widget, height = card_h }
end

return M
