--[[--
旧配置迁移：拆分前的大分区（common.lua、settings/display.lua 等）里的键，
在拥有者首次打开自己的文件时搬过去。只给 utils.settings 用。

@module koplugin.book.utils.settings_legacy
--]]

local Paths = require("utils.paths")

local Legacy = {}

-- common 在 common.lua，其余 settings/<name>.lua。
local SECTIONS = { "common", "display", "reader", "home", "ai", "maintenance", "pinyin", "quickpanel" }

-- 改过名的键：新键名 → 旧分区里的旧键名。v0.2.0 的 keyboard feature（settings/keyboard.lua 的
-- enabled）并进 ime 后叫 hide_key；默认开，不搬的话关掉它的用户升级后又开了。
local RENAMED = {
    hide_key = { section = "keyboard", key = "enabled" },
}

--- 把 keys 从旧分区搬进 file：新文件已有的值优先，旧分区里的一律删掉。
--- 不落盘：调用方先 flush 新文件再 flush 返回的旧分区，中途断电最多留一份重复，不会丢配置。
---@param file table 拥有者的 LuaSettings（与它同路径的旧分区跳过）
---@param keys string[]
---@param open fun(path: string): table 调用方的 LuaSettings 缓存（同一路径必须同一实例）
---@return table[] touched 删过键的旧分区
function Legacy.migrate(file, keys, open)
    local touched = {}
    --- 旧分区 legacy 的 old_key 搬到 file 的 key。
    ---@return boolean moved
    local function move(legacy, old_key, key)
        if legacy == file or legacy.data[old_key] == nil then return false end
        if file.data[key] == nil then file.data[key] = legacy.data[old_key] end
        legacy.data[old_key] = nil
        return true
    end
    for _idx, section in ipairs(SECTIONS) do
        local legacy = open(section == "common" and Paths.commonPath() or Paths.sectionPath(section))
        local dirty = false
        for _i, key in ipairs(keys) do
            dirty = move(legacy, key, key) or dirty
        end
        if dirty then touched[#touched + 1] = legacy end
    end
    for _i, key in ipairs(keys) do
        local renamed = RENAMED[key]
        if renamed then
            local legacy = open(Paths.sectionPath(renamed.section))
            if move(legacy, renamed.key, key) then touched[#touched + 1] = legacy end
        end
    end
    return touched
end

return Legacy
