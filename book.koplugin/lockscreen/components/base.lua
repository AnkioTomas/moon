--[[--
锁屏主体组件注册表。

@module koplugin.book.lockscreen.components.base
--]]

local _ = require("gettext")

local M = {}

-- 新增主体只需新增 components/<name>.lua，并在这里登记一次；资源下载、
-- 每日更新和锁屏入口都不需要跟着增加分支。
local COMPONENT_MODULES = {
    "stats", "hitokoto", "highlight", "current", "bill", "message", "myrl", "bookshelf",
}

-- “无”仍是一个合法主体，方便只显示背景而不引入额外的空值分支。
local None = {
    id = "none",
    label = _("无"),
    supports_narrow = true,
    supports_position = false,
    blocks = function() return {} end,
}

-- 顺序同时决定设置页的展示顺序；组件对象只描述能力，不保存运行状态。
M.components = {
    None,
}

for i = #COMPONENT_MODULES, 1, -1 do
    local component = require("lockscreen.components." .. COMPONENT_MODULES[i])
    if component.supports_narrow == nil then component.supports_narrow = true end
    table.insert(M.components, 1, component)
end

--- 按稳定 ID 查找主体配置。
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

--- 将主体配置转换为设置页需要的选项结构。
---@return {text: string, value: string}[]
function M.options()
    local items = {}
    for _, component in ipairs(M.components) do
        items[#items + 1] = { text = component.label, value = component.id }
    end
    return items
end

return M
