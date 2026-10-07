--[[--
旧配置迁移：拆分前的大分区（common.lua、settings/display.lua 等）里的键，
在拥有者首次打开自己的文件时搬过去。只给 utils.settings 用。

@module koplugin.book.utils.settings_legacy
--]]

local Paths = require("utils.paths")

local Legacy = {}

-- common 在 common.lua，其余 settings/<name>.lua。
local SECTIONS = { "common", "display", "reader", "home", "ai", "maintenance", "pinyin", "quickpanel" }

--- 把 keys 从旧分区搬进 file：新文件已有的值优先，旧分区里的一律删掉。
--- 不落盘：调用方先 flush 新文件再 flush 返回的旧分区，中途断电最多留一份重复，不会丢配置。
---@param file table 拥有者的 LuaSettings（与它同路径的旧分区跳过）
---@param keys string[]
---@param open fun(path: string): table 调用方的 LuaSettings 缓存（同一路径必须同一实例）
---@return table[] touched 删过键的旧分区
function Legacy.migrate(file, keys, open)
    local touched = {}
    for _idx, section in ipairs(SECTIONS) do
        local legacy = open(section == "common" and Paths.commonPath() or Paths.sectionPath(section))
        local dirty = false
        if legacy ~= file then
            for _i, key in ipairs(keys) do
                if legacy.data[key] ~= nil then
                    if file.data[key] == nil then file.data[key] = legacy.data[key] end
                    legacy.data[key] = nil
                    dirty = true
                end
            end
        end
        if dirty then touched[#touched + 1] = legacy end
    end
    return touched
end

return Legacy
