--[[--
主体：最近阅读封面堆叠（9 槽对称分配、向心重叠、底边齐平）。

@module koplugin.book.ui.desktop.home.components.recent_cards
--]]

local BookInfo = require("ui.components.bookinfo")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local _ = require("gettext")

local M = {
    id = "recent_cards",
    label = _("最近阅读卡片"),
    icon = "collections_bookmark",
}

local PREFERRED_H = UI.sz(200)
local SLOT_COUNT = 9
local CENTER_SLOT = 5
local SCALE_LEG = 0.88
local SCALE_OUTER = 0.76
local STACK_PULL = UI.sz(14)

-- 由近到远对称填充：4,6 → 3,7 → 2,8 → 1,9
local FILL_RING = { 4, 6, 3, 7, 2, 8, 1, 9 }
-- 绘制顺序：远 → 近，正中最后（叠在最上）
local PAINT_ORDER = { 1, 9, 2, 8, 3, 7, 4, 6, 5 }

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

local function slotScale(main_cw, main_ch, dist)
    if dist == 0 then
        return main_cw, main_ch
    end
    if dist == 1 then
        return math.max(UI.sz(46), math.floor(main_cw * SCALE_LEG)),
            math.max(UI.sz(69), math.floor(main_ch * SCALE_LEG))
    end
    return math.max(UI.sz(40), math.floor(main_cw * SCALE_OUTER)),
        math.max(UI.sz(60), math.floor(main_ch * SCALE_OUTER))
end

--- 封面；仅主封面叠底栏进度。
local function coverStack(ctx, book, cw, ch, on_tap, opts)
    opts = opts or {}
    local cover = select(1, BookInfo.cover(ctx.plugin, ctx.source, book, cw, ch, {
        badge = false,
        shadow = false,
        show_parent = ctx.desktop,
    }))
    local body = cover
    if opts.show_progress then
        local pct = BookInfo.pct(book) or 0
        local bar_pad = UI.sz(4)
        local bar_h = UI.sz(8)
        local stack = OverlapGroup:new{
            dimen = Geom:new{ w = cw, h = ch },
            show_parent = ctx.desktop,
            cover,
        }
        local bar_w = math.max(UI.sz(20), cw - bar_pad * 2)
        local bar = UI.progressBar(bar_w, bar_h, pct)
        bar.overlap_offset = { bar_pad, ch - bar_h - bar_pad }
        table.insert(stack, bar)
        body = stack
    end
    if not on_tap then
        return FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            dimen = Geom:new{ w = cw, h = ch },
            body,
        }
    end
    local tap = BookInfo.tappable(cw, ch, on_tap)
    tap[1] = body
    return tap
end

---@param books table[]
---@return table
local function assignSlots(books)
    local slots = {}
    slots[CENTER_SLOT] = { book = books[1], index = 1 }
    for i = 2, #books do
        local slot = FILL_RING[i - 1]
        if slot then
            slots[slot] = { book = books[i], index = i }
        end
    end
    return slots
end

---@param slot_idx number
---@param pad number
---@param pitch number
---@return number
local function slotCenterX(slot_idx, pad, pitch)
    return pad + pitch * (slot_idx - 0.5)
end

--- 向心偏移：两侧封面往中间叠，形成堆叠。
---@param slot_idx number
---@param cx number
---@param cw number
---@param pad number
---@param avail_w number
---@return number
local function stackX(slot_idx, cx, cw, pad, avail_w)
    local dist = slot_idx - CENTER_SLOT
    local x = math.floor(cx - cw / 2)
    if dist < 0 then
        x = x + STACK_PULL * (-dist)
    elseif dist > 0 then
        x = x - STACK_PULL * dist
    end
    return math.max(pad, math.min(x, pad + avail_w - cw))
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
    local _, on_read = openHandlers(ctx)

    if not recent then
        local tw = TextWidget:new{
            text = state.recent_err or _("去图书馆挑一本 ›"),
            face = UI.face("cfont", 14),
            fgcolor = UI.muted(),
        }
        return {
            widget = CenterContainer:new{
                dimen = Geom:new{ w = w, h = h },
                tw,
            },
            height = h,
        }
    end

    local books = { recent }
    for i, book in ipairs(reading) do
        if #books < SLOT_COUNT then
            books[#books + 1] = book
        end
    end

    local pad = UI.sz(10)
    local avail_w = math.max(1, w - pad * 2)
    local avail_h = math.max(1, h - pad * 2)
    local pitch = avail_w / SLOT_COUNT

    local main_cw = math.min(UI.sz(108), math.floor(avail_w * 0.34))
    main_cw, main_ch = UI.coverDim(main_cw)
    if main_ch > avail_h - UI.sz(8) then
        main_ch = avail_h - UI.sz(8)
        main_cw = math.max(UI.sz(56), math.floor(main_ch * 2 / 3))
        main_cw, main_ch = UI.coverDim(main_cw)
    end

    local slots = assignSlots(books)
    local row_bottom = math.floor((h + main_ch) / 2)

    local overlap = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        overlap_offset = { 0, 0 },
    }

    for i, slot_idx in ipairs(PAINT_ORDER) do
        local entry = slots[slot_idx]
        if entry then
            local dist = math.abs(slot_idx - CENTER_SLOT)
            local cw, ch = slotScale(main_cw, main_ch, dist)
            local cx = slotCenterX(slot_idx, pad, pitch)
            local x = stackX(slot_idx, cx, cw, pad, avail_w)
            local y = row_bottom - ch
            local book = entry.book
            local on_tap = slot_idx == CENTER_SLOT and function() on_read(book) end
            local cell = coverStack(ctx, book, cw, ch, on_tap, {
                show_progress = slot_idx == CENTER_SLOT,
            })
            cell.overlap_offset = { x, y }
            table.insert(overlap, cell)
        end
    end

    local widget = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        dimen = Geom:new{ w = w, h = h },
        overlap,
    }
    return { widget = widget, height = h }
end

return M
