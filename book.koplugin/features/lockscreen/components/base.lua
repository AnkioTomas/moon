--[[--
锁屏主体组件注册表。

@module koplugin.book.features.lockscreen.components.base
--]]

local _ = require("gettext")
local logger = require("utils.log")

local M = {}

-- 新增主体只需新增 components/<name>.lua，并在这里登记一次；资源下载、
-- 每日更新和锁屏入口都不需要跟着增加分支。
-- 第三方插件经 moon_source.lua 的 provides.features.lockscreen 再追加，不写进这张表。
local COMPONENT_MODULES = {
    "stats", "hitokoto", "highlight", "current", "capsule", "minimal",
    "receipt", "bill", "message",
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
    local component = require("features.lockscreen.components." .. COMPONENT_MODULES[i])
    if component.supports_narrow == nil then component.supports_narrow = true end
    table.insert(M.components, 1, component)
end

--- 第三方锁屏主体。插件未加载完时列表为空，第二返回值为假。
--- 不合格的条目记日志跳过。
---@return table[] components, boolean ready
local function externalComponents()
    local ok, External = pcall(require, "utils.external")
    if not ok then return {}, true end
    local items, ready = External.collect("lockscreen")
    local out, seen = {}, {}
    for _idx, component in ipairs(M.components) do
        if component.id then seen[component.id] = true end
    end
    for _idx, item in ipairs(items) do
        local list = External.try(item.id .. " lockscreen", item.mod.components)
        if type(list) ~= "table" or list.id then
            if list ~= nil then
                logger.error("feature external lockscreen rejected: components must return a list", item.id)
            end
        else
            for _i, raw in ipairs(list) do
                local id = type(raw) == "table" and External.prefix(item.id, raw.id)
                local why = not id and "component needs id"
                    or seen[id] and "duplicate id"
                    or type(raw.label) ~= "string" and "component needs label"
                    or type(raw.blocks) ~= "function" and "component needs blocks"
                if why then
                    logger.error("feature external lockscreen rejected", item.id, why)
                else
                    seen[id] = true
                    local label = id .. " blocks"
                    out[#out + 1] = {
                        id = id,
                        label = raw.label,
                        supports_narrow = raw.supports_narrow ~= false,
                        supports_position = raw.supports_position,
                        preferred_height = raw.preferred_height,
                        min_height = raw.min_height,
                        layout = raw.layout,
                        full_screen = raw.full_screen,
                        needs_network = raw.needs_network,
                        cache_key = type(raw.cache_key) == "function" and function()
                            return External.try(id .. " cache_key", raw.cache_key)
                        end or nil,
                        blocks = function(...)
                            local result = External.try(label, raw.blocks, ...)
                            if type(result) ~= "table" then return {} end
                            return result
                        end,
                    }
                end
            end
        end
    end
    return out, ready
end

--- 按稳定 ID 查找主体配置。内置优先，再问已加载的第三方插件。
---@param id string|nil
---@return table|nil
function M.find(id)
    for _idx, component in ipairs(M.components) do
        if component.id == id then
            return component
        end
    end
    for _idx, component in ipairs(externalComponents()) do
        if component.id == id then
            return component
        end
    end
end

--- 插件还在加载时，认不出的 id 先留着，避免开机把第三方主体冲掉。
---@param id string|nil
---@return boolean
function M.resolvable(id)
    if M.find(id) then return true end
    local _, ready = externalComponents()
    return not ready
end

--- 将主体配置转换为设置页需要的选项结构。
---@return {text: string, value: string}[]
function M.options()
    local items = {}
    for _idx, component in ipairs(M.components) do
        items[#items + 1] = { text = component.label, value = component.id }
    end
    for _idx, component in ipairs(externalComponents()) do
        items[#items + 1] = { text = component.label, value = component.id }
    end
    return items
end

return M
