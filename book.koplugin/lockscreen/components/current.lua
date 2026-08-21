--[[--
主体：当前阅读（章节 / 进度 / 剩余条）。

@module koplugin.book.lockscreen.components.current
--]]

local Context = require("lockscreen.context")
local Blitbuffer = require("ffi/blitbuffer")
local U = require("lockscreen.components.util")
local _ = require("gettext")

local M = {
    id = "current",
    label = _("当前阅读"),
    supports_narrow = true,
    needs_network = false,
}

---@param rect table
---@return table[]
function M.blocks(rect)
    local book = Context.currentBook()
    if not book then
        return U.emptyBlocks(rect, _("当前阅读"), _("当前没有正在阅读的书籍"))
    end
    local inner_x, inner_w = rect.text_x, rect.text_w
    local pad = rect.pad
    return {
        {
            kind = "panel", x = rect.x, y = rect.y, width = rect.w, height = rect.h,
            radius = rect.radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            text = U.chapterLine(book), x = inner_x, y = rect.y + pad,
            width = inner_w, size = 20, bold = true, box = false,
        },
        {
            text = U.progressLine(book), x = inner_x, y = rect.y + pad + math.floor(rect.h * 0.32),
            width = inner_w * 0.55, size = 15, box = false, color = U.MUTED,
        },
        {
            text = U.remainingLine(book),
            x = math.floor(inner_x + inner_w * 0.45), y = rect.y + pad + math.floor(rect.h * 0.32),
            width = math.floor(inner_w * 0.55), size = 15, align = "right", box = false, color = U.MUTED,
        },
        {
            kind = "bar", x = inner_x, y = rect.y + rect.h - pad - 10,
            width = inner_w, height = 8, value = (book.percent or 0) / 100,
        },
    }
end

return M
