--[[--
锁屏主体组件注册表。

@module koplugin.book.lockscreen.components.base
--]]

local Stats = require("lockscreen.components.stats")
local Hitokoto = require("lockscreen.components.hitokoto")
local Highlight = require("lockscreen.components.highlight")
local Current = require("lockscreen.components.current")
local Bookmark = require("lockscreen.components.bookmark")
local CoverCards = require("lockscreen.components.cover_cards")
local Bill = require("lockscreen.components.bill")
local _ = require("gettext")

local M = {}

local None = {
    id = "none",
    label = _("无"),
    supports_narrow = true,
    needs_network = false,
    blocks = function()
        return {}
    end,
}

--- 顺序即设置页选项顺序。
M.components = {
    Stats,
    Hitokoto,
    Highlight,
    Current,
    Bookmark,
    CoverCards,
    Bill,
    None,
}

---@param id string|nil
---@return table|nil
function M.find(id)
    for _, component in ipairs(M.components) do
        if component.id == id then
            return component
        end
    end
    return nil
end

---@return {text: string, value: string}[]
function M.options()
    local items = {}
    for _, component in ipairs(M.components) do
        items[#items + 1] = { text = component.label, value = component.id }
    end
    return items
end

return M
