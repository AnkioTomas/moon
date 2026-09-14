--[[--
首页组件注册表。

@module koplugin.book.ui.desktop.home.registry
--]]

local MoonSettings = require("utils.settings")
local Widgets = require("ui.desktop.home.widgets")

---@class BookHomeRegistry
---@field components BookHomeComponent[]
local M = {}

local COMPONENT_MODULES = {
    "clock", "weather", "clock_weather", "stats", "hitokoto", "excerpt",
    "history", "news",
    "recent_hero", "recent_list", "recent_cards",
}

M.components = {}
local by_id = {}

for _, name in ipairs(COMPONENT_MODULES) do
    local component = require("ui.desktop.home.views." .. name)
    M.components[#M.components + 1] = component
    by_id[component.id] = component
end

--- 按 id 查找组件定义。
---@param id string|nil
---@return BookHomeComponent|nil
function M.find(id)
    return id and by_id[id] or nil
end

--- 当前钉页放置表（已净化）。
---@return BookHomeWidgetPlacement[]
function M.widgets()
    return Widgets.load(M.find)
end

--- 写回放置表。
---@param list BookHomeWidgetPlacement[]
function M.saveWidgets(list)
    Widgets.save(Widgets.compactPages(list))
end

--- 读取并净化用户启用的有序组件 id 列表（全局 page/order）。
---@return string[]
function M.enabledLayout()
    return Widgets.ids(M.widgets())
end

--- 是否尚未按真实屏幕高度生成首页布局。
---@return boolean
function M.needsLayout()
    return MoonSettings.get("home").home_widgets == nil
end

return M
