--[[--
首页组件注册表。内置组件在前，第三方源描述表的 `home`（组件数组）按源顺序追加在后；
第三方组件 id 必须是 `ext.` 开头，免得占掉内置组件以后要用的名字。插件被禁用时它的组件
消失，放置表净化时随之丢弃。

@module koplugin.book.desktop.pages.home.registry
--]]

local MoonSettings = require("utils.settings")
local Widgets = require("desktop.pages.home.placements")
local logger = require("utils.log")

---@class BookHomeRegistry
---@field components BookHomeComponent[]
local M = {}

local COMPONENT_MODULES = {
    "clock", "weather", "clock_weather", "weather_forecast", "stats", "hitokoto", "excerpt",
    "history", "news",
    "recent_hero", "recent_list", "recent_cards",
}

M.components = {}
local by_id = {}

for _idx, name in ipairs(COMPONENT_MODULES) do
    local component = require("desktop.pages.home." .. name)
    M.components[#M.components + 1] = component
    by_id[component.id] = component
end

local Sources = require("source.registry")
for _idx, meta in ipairs(Sources.list()) do
    local desc = Sources.external(meta.id)
    for _cidx, component in ipairs(desc and desc.home or {}) do
        local id = component.id
        if type(id) == "string" and id:match("^ext%.") and not by_id[id] then
            M.components[#M.components + 1] = component
            by_id[id] = component
        else
            logger.err("desktop.home external component rejected", meta.id, id)
        end
    end
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
    return Widgets.load(M.components)
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
    return MoonSettings.get("desktop.pages.home").home_widgets == nil
end

return M
