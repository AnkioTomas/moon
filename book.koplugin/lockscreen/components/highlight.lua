--[[--
主体：阅读高亮。

@module koplugin.book.lockscreen.components.highlight
--]]

local Context = require("lockscreen.context")
local QuotePanel = require("lockscreen.components.quote_panel")
local _ = require("gettext")

local FALLBACK = "读书不觉已春深，一寸光阴一寸金。"

local M = {
    id = "highlight",
    label = _("阅读高亮"),
    supports_narrow = true,
    needs_network = false,
}

---@param position string
---@param wide boolean
---@return table[]
function M.blocks(position, wide)
    local highlight = Context.highlight()
    local text = highlight or FALLBACK
    local source = highlight and _("来自当前书籍高亮") or _("默认句子")
    return QuotePanel.blocks(text, source, position, wide)
end

return M
