--[[--
主体：封面卡片。当前书封面铺满做背景，贴底叠半透明卡：书名、进度、今日阅读 / 预计剩余。

@module koplugin.book.lockscreen.components.cover_card
--]]

local Background = require("lockscreen.background")
local Cards = require("lockscreen.components.cards")
local _ = require("gettext")

local M = {
    id = "cover_card",
    label = _("封面卡片"),
    supports_position = false,
    full_screen = true,
    uses_background = false,
    asset = Background.background("cover"),
}

---@param rect table 全屏矩形
---@return table[]
function M.blocks(rect)
    -- 封面本身就是背景，卡里不再放缩略图。
    return Cards.stack(rect, { thumb = false, lighten = 0.75, title_size = 24 })
end

return M
