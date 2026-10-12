--[[--
主体：胶囊卡片。背景上贴底叠一组卡：封面书卡、进度、今日阅读 / 预计剩余。

@module koplugin.book.features.lockscreen.components.capsule
--]]

local Cards = require("features.lockscreen.components.cards")
local MoonSettings = require("utils.settings")
local _ = require("gettext")

local M = {
    id = "capsule",
    label = _("胶囊卡片"),
    supports_position = false,
    full_screen = true,
    cache_key = require("features.lockscreen.components.current").cache_key,
}

---@param rect table 全屏矩形
---@return table[]
function M.blocks(rect)
    -- 背景已是当前书封面：卡里不再放同一张缩略图，改半透明卡露出封面。
    if MoonSettings.get("features.lockscreen").lock_screen_background == "cover" then
        return Cards.stack(rect, { thumb = false, lighten = 0.75, title_size = 24 })
    end
    return Cards.stack(rect, { thumb = true, title_size = 20 })
end

return M
