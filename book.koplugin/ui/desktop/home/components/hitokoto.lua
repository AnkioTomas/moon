--[[--
主体：一言。

@module koplugin.book.ui.desktop.home.components.hitokoto
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextWidget = require("ui/widget/textwidget")
local MoonSettings = require("utils.settings")
local Surface = require("ui.components.surface")
local UI = require("ui.components.bookui")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local U = require("lockscreen.components.util")
local _ = require("gettext")

local M = {
    id = "hitokoto",
    label = _("一言"),
}

---@param ctx table
---@param state table
---@param opts table
---@return table
function M.build(ctx, state, opts)
    local w = opts.width
    local pad = UI.sz(12)
    local quote = state.quote or {}
    local text = quote.text or MoonSettings.get().lock_screen_quote_cache or U.FALLBACK_MESSAGE
    local source = quote.source or MoonSettings.get().lock_screen_quote_source_cache or _("一言")
    local inner_w = math.max(1, w - pad * 4)
    local body = TextWidget:new{
        text = text,
        face = UI.face("cfont", 15),
        max_width = inner_w,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local src_w = TextWidget:new{
        text = source,
        face = UI.face("xx_smallinfofont", 12),
        max_width = inner_w,
        fgcolor = UI.muted(),
    }
    local inner_h = body:getSize().h + UI.sz(8) + src_w:getSize().h
    local card_h = inner_h + pad * 2
    local content = VerticalGroup:new{
        align = "left",
        body,
        VerticalSpan:new{ width = UI.sz(8) },
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
        width = w,
        height = card_h,
        padding = pad,
        shadow = true,
    })
    return { widget = card, height = card_h }
end

return M
