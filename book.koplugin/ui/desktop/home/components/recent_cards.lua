--[[--
主体：最近阅读卡片堆叠。

@module koplugin.book.ui.desktop.home.components.recent_cards
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BookInfo = require("ui.components.bookinfo")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local Surface = require("ui.components.surface")
local U = require("lockscreen.components.util")
local _ = require("gettext")

local M = {
    id = "recent_cards",
    label = _("最近阅读卡片"),
}

local PREFERRED_H = UI.sz(200)

local function chapterSubtitle(book)
    local chapter = U.chapterLine(book)
    return chapter ~= "" and (_("章节") .. " · " .. chapter) or nil
end

local function openHandlers(ctx)
    local on_open = function(book)
        if ctx.desktop and ctx.desktop.showDetail then
            ctx.desktop:showDetail(book)
        end
    end
    local on_read = function(book)
        local plugin = ctx.plugin or (ctx.desktop and ctx.desktop.plugin)
        if plugin and plugin.openBook then
            plugin:openBook(book)
        else
            on_open(book)
        end
    end
    return on_open, on_read
end

---@param ctx table
---@param state table
---@param opts table
---@return table
function M.build(ctx, state, opts)
    local w = opts.width
    local h = math.min(opts.budget or PREFERRED_H, PREFERRED_H)
    local recent = state.recent
    local reading = state.reading or {}
    local on_open, on_read = openHandlers(ctx)

    if not recent then
        local tw = TextWidget:new{
            text = state.recent_err or _("去图书馆挑一本 ›"),
            face = UI.face("cfont", 14),
            fgcolor = UI.muted(),
        }
        local widget = CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            tw,
        }
        return { widget = widget, height = h }
    end

    local pad = UI.sz(10)
    local stack_h = h - pad
    local hero_w = math.min(w - pad * 2, math.floor(w * 0.88))
    local hero, hero_h = BookInfo.hero(ctx.plugin, ctx.source, recent, {
        width = hero_w,
        pad = UI.sz(8),
        subtitle = chapterSubtitle(recent),
        show_parent = ctx.desktop,
        on_tap = function() on_read(recent) end,
        sync = true,
    })
    local card_h = math.min(hero_h + UI.sz(16), stack_h)
    local main_card = Surface.card(CenterContainer:new{
        dimen = Geom:new{ w = hero_w, h = hero_h },
        hero,
    }, {
        width = hero_w,
        height = card_h,
        padding = UI.sz(8),
        shadow = true,
    })

    local overlap = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = stack_h },
        overlap_offset = { 0, 0 },
    }
    table.insert(overlap, CenterContainer:new{
        dimen = Geom:new{ w = w, h = stack_h },
        main_card,
    })

    local peek_count = math.min(3, #reading)
    for i = peek_count, 1, -1 do
        local book = reading[i]
        local cw = math.floor(hero_w * (0.55 + (peek_count - i) * 0.08))
        local ch = math.floor(cw * 3 / 2)
        local cover = select(1, BookInfo.cover(ctx.plugin, ctx.source, book, cw, ch, {
            badge = true,
            show_parent = ctx.desktop,
        }))
        local y_off = stack_h - ch + UI.sz(4) + (i - 1) * UI.sz(6)
        local x_off = math.floor((w - cw) / 2) + (i - 1) * UI.sz(10)
        local tap = BookInfo.tappable(cw, ch, function() on_open(book) end)
        tap[1] = cover
        tap.overlap_offset = { x_off, y_off }
        table.insert(overlap, tap)
    end

    local widget = FrameContainer:new{
        bordersize = 0,
        padding = pad,
        padding_top = 0,
        margin = 0,
        dimen = Geom:new{ w = w, h = h },
        overlap,
    }
    return { widget = widget, height = h }
end

return M
