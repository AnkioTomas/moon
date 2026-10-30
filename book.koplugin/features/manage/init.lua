--[[--
功能开关：用户可以停用不用的 feature（不加载，省内存与启动时间），文件不动，随时可再启用。

只停用被点的那个，不连带别的 feature：其它 feature 若直接引用它，文件还在，照常 require，只是它的钩子、
设置页、快捷开关等约定入口不再登记。名称、说明、能力清单与是否可停用写在各 feature 的 `_meta.lua`（`removable = false` 不开放停用，如 `update` 保证始终能自更新）。

设置里只记「停用谁」（`features.manage.disabled`），下次启动加载器按它跳过这些 feature：
当前进程里已加载的模块还在用，不能当场卸载。

@module koplugin.book.features.manage
--]]

require("l10n").apply()
local _ = require("gettext")

local Manage = {}

local FEATURES_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+/[^/]+$")

---@class BookRemovableFeature
---@field id string features 下的目录名
---@field label string
---@field subtitle string
---@field abilities string[]

local items

--- 可停用的 feature：扫 features/<name>/_meta.lua，removable == false 的不列（如 update、manage）。
---@return BookRemovableFeature[]
function Manage.items()
    if items then return items end
    local lfs = require("libs/libkoreader-lfs")
    items = {}
    for name in lfs.dir(FEATURES_DIR) do
        if name:sub(1, 1) ~= "." and lfs.attributes(FEATURES_DIR .. "/" .. name .. "/_meta.lua", "mode") == "file" then
            local meta = require("features." .. name .. "._meta")
            if meta.removable ~= false then
                items[#items + 1] = {
                    id = name, label = meta.name, subtitle = meta.description, abilities = meta.abilities,
                }
            end
        end
    end
    table.sort(items, function(a, b) return a.id < b.id end)
    return items
end

---@param id string
---@return boolean
local function removable(id)
    for _idx, item in ipairs(Manage.items()) do
        if item.id == id then return true end
    end
    return false
end

---@return string[]
local function marked()
    return require("utils.settings").get("features.manage").disabled
end

---@param id string
---@return boolean
function Manage.isMarked(id)
    for _idx, name in ipairs(marked()) do
        if name == id then return true end
    end
    return false
end

--- 标记 / 取消标记；返回现在是否已标记。只动 id 自己，不连带别的 feature。
---@param id string
---@return boolean
function Manage.toggle(id)
    local MoonSettings = require("utils.settings")
    local s = MoonSettings.get("features.manage")
    local was = Manage.isMarked(id)
    local keep = {}
    for _idx, name in ipairs(s.disabled) do
        if name ~= id then keep[#keep + 1] = name end
    end
    if not was then keep[#keep + 1] = id end
    s.disabled = keep
    MoonSettings.save("features.manage", s)
    return not was
end

--- 加载器在 require 任何 feature 之前调：把已停用的从 list 里去掉，返回停用集合（目录扫描用）。
---@param list string[] Features.list（就地修改）
---@return table<string, boolean>
function Manage.apply(list)
    local off = {}
    for _idx, id in ipairs(marked()) do
        if removable(id) then
            off[id] = true
            for i = #list, 1, -1 do
                if list[i] == id then table.remove(list, i) end
            end
        end
    end
    return off
end

return Manage
