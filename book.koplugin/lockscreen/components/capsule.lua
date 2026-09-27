--[[--
主体：胶囊卡片。用户背景上贴底叠一组白卡：封面书卡、进度、今日阅读 / 预计剩余。

@module koplugin.book.lockscreen.components.capsule
--]]

local Cards = require("lockscreen.components.cards")
local _ = require("gettext")

local M = {
    id = "capsule",
    label = _("胶囊卡片"),
    supports_position = false,
    full_screen = true,
}

---@param rect table 全屏矩形
---@return table[]
function M.blocks(rect)
    return Cards.stack(rect, { thumb = true, title_size = 20 })
end

return M
