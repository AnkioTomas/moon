--[[--
主体：阅读统计（时长 + 近 7 日柱图）。仅宽屏。

@module koplugin.book.lockscreen.components.stats
--]]

local Context = require("lockscreen.context")
local Chart = require("ui.components.chart")
local Blitbuffer = require("ffi/blitbuffer")
local U = require("lockscreen.components.util")
local _ = require("gettext")

local M = {
    id = "stats",
    label = _("阅读统计"),
    supports_narrow = false,
    needs_network = false,
}

---@param rect table
---@return table[]
function M.blocks(rect)
    local book = Context.currentBook()
    if not book then
        return U.emptyBlocks(rect, _("阅读统计"), _("当前没有正在阅读的书籍"))
    end
    local buckets = book.buckets or {}
    local week_seconds = 0
    for _, slot in ipairs(buckets) do
        week_seconds = week_seconds + (slot.seconds or 0)
    end
    local day_avg = week_seconds / math.max(1, #buckets)
    local inner_x, inner_w = rect.text_x, rect.text_w
    local card_y, card_h = rect.y, rect.h
    local pad = rect.pad
    local blocks = {
        {
            kind = "panel", x = rect.x, y = card_y, width = rect.w, height = card_h,
            radius = rect.radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            text = _("阅读统计"), x = inner_x, y = card_y + pad,
            width = inner_w, size = 16, box = false, color = U.MUTED,
        },
        {
            kind = "rule", x = inner_x, y = card_y + pad + 26,
            width = inner_w, height = 1,
        },
        {
            text = string.format("%.0f%%", book.percent or 0),
            x = inner_x, y = math.floor(card_y + card_h * 0.16),
            width = inner_w * 0.42, size = 40, bold = true, box = false,
        },
        {
            text = _("累计阅读"),
            x = math.floor(inner_x + inner_w * 0.45), y = math.floor(card_y + card_h * 0.17),
            width = math.floor(inner_w * 0.55), size = 13, align = "right", box = false, color = U.MUTED,
        },
        {
            text = U.duration(book.total_seconds),
            x = math.floor(inner_x + inner_w * 0.45), y = math.floor(card_y + card_h * 0.22),
            width = math.floor(inner_w * 0.55), size = 18, bold = true, align = "right", box = false,
        },
        {
            kind = "bar", x = inner_x, y = math.floor(card_y + card_h * 0.34),
            width = inner_w, height = 8, value = (book.percent or 0) / 100,
        },
        {
            text = U.progressLine(book) .. "  ·  " .. U.remainingLine(book),
            x = inner_x, y = math.floor(card_y + card_h * 0.40),
            width = inner_w, size = 14, box = false, color = U.DIM,
        },
        {
            kind = "rule", x = inner_x, y = math.floor(card_y + card_h * 0.48),
            width = inner_w, height = 1,
        },
        {
            text = _("最近 7 天"),
            x = inner_x, y = math.floor(card_y + card_h * 0.52),
            width = inner_w * 0.5, size = 15, bold = true, box = false,
        },
        {
            text = _("日均") .. " " .. U.duration(day_avg),
            x = math.floor(inner_x + inner_w * 0.45), y = math.floor(card_y + card_h * 0.52),
            width = math.floor(inner_w * 0.55), size = 14, align = "right", box = false, color = U.MUTED,
        },
    }
    Chart.appendBars(blocks, {
        points = buckets,
        value_key = "seconds",
        x = inner_x,
        y = math.floor(card_y + card_h * 0.62),
        width = inner_w,
        height = math.floor(card_h * 0.28),
        label_color = U.DIM,
        label_mode = "all",
    })
    return blocks
end

return M
