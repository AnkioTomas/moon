--[[--
锁屏高亮主体：轮换展示划线句子。

@module koplugin.book.lockscreen.components.highlight
--]]

local Current = require("lockscreen.components.current")
local MoonSettings = require("utils.settings")
local Highlights = require("book.highlights")
local QuotePanel = require("lockscreen.components.quote_panel")
local U = require("lockscreen.components.util")
local _ = require("gettext")

local M = {
    id = "highlight",
    label = _("阅读高亮"),
    layout = "quote",
}

--- 轮换一条当前书高亮，并生成章节/页码出处。
---@return string|nil, string|nil
function M.next()
    local book = Current.book()
    if not book then return nil end
    local source_id = book.source_id
    local stable_id = book.stable_id
    local chapter_idx = book.chapter_idx
    local items = Highlights.collect(source_id, stable_id, chapter_idx)
    if #items == 0 then return nil end

    local settings = MoonSettings.get()
    local index = (tonumber(settings.lock_screen_quote_index) or 0) % #items + 1
    settings.lock_screen_quote_index = index
    MoonSettings.save()
    return Highlights.pick(source_id, stable_id, chapter_idx, index)
end

-- quote 布局由 compose 传入位置和宽窄，组件只负责取得下一条高亮。
--- 没有高亮时使用公共默认句子，保证锁屏仍有可读内容。
---@param position string
---@param wide boolean
---@return table[]
function M.blocks(position, wide)
    local text, source = M.next()
    if not text then
        return QuotePanel.blocks(U.FALLBACK_MESSAGE, _("默认句子"), position, wide)
    end
    return QuotePanel.blocks(text, source or _("来自当前书籍高亮"), position, wide)
end

return M
