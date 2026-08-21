--[[--
锁屏主体组件公共文案/时长辅助。

@module koplugin.book.lockscreen.components.util
--]]

local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")
local T = require("ffi/util").template

local U = {}

U.MUTED = Blitbuffer.COLOR_GRAY_3
U.DIM = Blitbuffer.COLOR_GRAY_4

---@param seconds number|nil
---@return string
function U.duration(seconds)
    local minutes = math.floor((tonumber(seconds) or 0) / 60)
    return minutes >= 60 and T(_("%1 小时 %2 分钟"), math.floor(minutes / 60), minutes % 60)
        or T(_("%1 分钟"), minutes)
end

---@param book table
---@return string
function U.chapterLine(book)
    if book.chapter_title and book.chapter_title ~= "" then
        return book.chapter_title
    end
    if book.chapter_count and book.chapter_count > 0 then
        return T(_("第 %1 / %2 章"), book.chapter_idx or 1, book.chapter_count)
    end
    return _("阅读中")
end

---@param book table
---@return string
function U.remainingLine(book)
    if book.remaining_pages and book.remaining_pages > 0 then
        return T(_("剩余 %1 页"), book.remaining_pages)
    end
    return T(_("剩余 %1%%"), math.floor(book.remaining_percent or 0))
end

---@param book table
---@return string
function U.progressLine(book)
    if book.total_pages and book.total_pages > 0 then
        return T(_("%1 / %2 页 · %3%%"), book.page, book.total_pages, math.floor(book.percent or 0))
    end
    return string.format("%.0f%%", book.percent or 0)
end

--- 空态白卡。
---@param rect table
---@param title string
---@param message string
---@return table[]
function U.emptyBlocks(rect, title, message)
    return {
        {
            kind = "panel", x = rect.x, y = rect.y, width = rect.w, height = rect.h,
            radius = rect.radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            text = title, x = rect.text_x, y = rect.y + rect.pad,
            width = rect.text_w, size = 18, box = false, color = U.MUTED,
        },
        {
            kind = "rule", x = rect.text_x, y = rect.y + rect.pad + 28,
            width = rect.text_w, height = 1,
        },
        {
            text = message,
            x = rect.text_x, y = rect.y + math.floor(rect.h * 0.48),
            width = rect.text_w, size = 20, align = "center", box = false, color = U.MUTED,
        },
    }
end

return U
