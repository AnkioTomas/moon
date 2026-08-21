--[[--
主体：阅读封面（左侧叠卡）。仅宽屏。

@module koplugin.book.lockscreen.components.cover_cards
--]]

local Context = require("lockscreen.context")
local Blitbuffer = require("ffi/blitbuffer")
local U = require("lockscreen.components.util")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {
    id = "cover_cards",
    label = _("阅读封面"),
    supports_narrow = false,
    needs_network = false,
}

---@param rect table
---@return table[]
function M.blocks(rect)
    local book = Context.currentBook()
    if not book then
        return U.emptyBlocks(rect, _("阅读封面"), _("当前没有正在阅读的书籍"))
    end

    local pad = rect.pad
    local radius = rect.radius
    local col_w = math.floor(rect.w * 0.92)
    local gap = math.max(10, math.floor(rect.h * 0.03))
    local y = rect.y
    local blocks = {}
    local x = rect.x

    local function pushCard(title, body, sub, card_h)
        blocks[#blocks + 1] = {
            kind = "panel", x = x, y = y, width = col_w, height = card_h,
            radius = radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        }
        blocks[#blocks + 1] = {
            text = title, x = x + pad, y = y + pad,
            width = col_w - pad * 2, size = 13, box = false, color = U.MUTED,
        }
        blocks[#blocks + 1] = {
            text = body, x = x + pad, y = y + pad + math.floor(card_h * 0.28),
            width = col_w - pad * 2, size = 18, bold = true, box = false,
        }
        if sub and sub ~= "" then
            blocks[#blocks + 1] = {
                text = sub, x = x + pad, y = y + card_h - pad - 18,
                width = col_w - pad * 2, size = 13, box = false, color = U.DIM,
            }
        end
        y = y + card_h + gap
    end

    local h1 = math.floor(rect.h * 0.24)
    local h2 = math.floor(rect.h * 0.38)
    local h3 = math.floor(rect.h * 0.26)
    pushCard(_("章节"), U.chapterLine(book), book.title or "", h1)

    local highlights = book.highlights or {}
    local highlight_text = highlights[1] or _("暂无高亮")
    if #highlight_text > 60 then
        highlight_text = highlight_text:sub(1, 57) .. "…"
    end
    local highlight_sub = #highlights > 1 and T(_("另有 %1 条"), #highlights - 1) or ""
    pushCard(_("高亮"), highlight_text, highlight_sub, h2)

    pushCard(
        _("进度"),
        string.format("%.0f%%", book.percent or 0),
        U.progressLine(book) .. "  ·  " .. U.remainingLine(book),
        h3
    )
    return blocks
end

return M
