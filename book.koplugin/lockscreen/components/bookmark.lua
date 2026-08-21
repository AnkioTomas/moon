--[[--
主体：阅读书签（书名 / 进度书签卡，无柱图）。

@module koplugin.book.lockscreen.components.bookmark
--]]

local Context = require("lockscreen.context")
local Blitbuffer = require("ffi/blitbuffer")
local U = require("lockscreen.components.util")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {
    id = "bookmark",
    label = _("阅读书签"),
    supports_narrow = true,
    needs_network = false,
}

---@param rect table
---@return table[]
function M.blocks(rect)
    local book = Context.currentBook()
    if not book then
        return U.emptyBlocks(rect, _("阅读书签"), _("当前没有正在阅读的书籍"))
    end
    local position = book.total_pages and book.total_pages > 0
        and T(_("%1 / %2 页"), book.page, book.total_pages) or ""
    local chapter = U.chapterLine(book)
    local meta = table.concat({ position, U.remainingLine(book) }, "  ·  ")
    local inner_x, inner_w = rect.text_x, rect.text_w
    local card_y, card_h = rect.y, rect.h
    local pad = rect.pad
    return {
        {
            kind = "panel", x = rect.x, y = card_y, width = rect.w, height = card_h,
            radius = rect.radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            text = _("阅读书签"), x = inner_x, y = card_y + pad,
            width = inner_w, size = 16, box = false, color = U.MUTED,
        },
        {
            kind = "rule", x = inner_x, y = card_y + pad + 26,
            width = inner_w, height = 1,
        },
        {
            text = book.title or "", x = inner_x, y = math.floor(card_y + card_h * 0.18),
            width = inner_w, size = 24, bold = true, box = false,
        },
        {
            text = (book.authors and book.authors ~= "" and book.authors) or chapter,
            x = inner_x, y = math.floor(card_y + card_h * 0.36),
            width = inner_w, size = 15, box = false, color = U.MUTED,
        },
        {
            text = string.format("%.0f%%", book.percent or 0),
            x = inner_x, y = math.floor(card_y + card_h * 0.52),
            width = inner_w * 0.42, size = 40, bold = true, box = false,
        },
        {
            kind = "bar", x = inner_x, y = math.floor(card_y + card_h * 0.72),
            width = inner_w, height = 8, value = (book.percent or 0) / 100,
        },
        {
            text = meta, x = inner_x, y = math.floor(card_y + card_h * 0.82),
            width = inner_w, size = 14, box = false, color = U.DIM,
        },
    }
end

return M
