--[[--
首页组件注册表。

@module koplugin.book.ui.desktop.home.components.base
--]]

local MoonSettings = require("utils.settings")
local _ = require("gettext")

local M = {}

local DEFAULT_COMPONENT = "recent_list"

local COMPONENT_MODULES = {
    "clock", "stats", "hitokoto", "excerpt", "recent_list", "recent_cards",
}

M.components = {}
local by_id = {}

for _, name in ipairs(COMPONENT_MODULES) do
    local component = require("ui.desktop.home.components." .. name)
    M.components[#M.components + 1] = component
    by_id[component.id] = component
end

--- 按 id 查找组件定义。
---@param id string|nil
---@return table|nil
function M.find(id)
    return id and by_id[id] or nil
end

--- 读取并净化用户启用的有序组件 id 列表。
---@return string[]
function M.enabledLayout()
    local raw = MoonSettings.get("home").home_layout
    if type(raw) ~= "table" or #raw == 0 then
        return { DEFAULT_COMPONENT }
    end
    local out, seen = {}, {}
    for _, id in ipairs(raw) do
        if type(id) == "string" and id ~= "" and not seen[id] and M.find(id) then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    if #out == 0 then
        return { DEFAULT_COMPONENT }
    end
    return out
end

return M
