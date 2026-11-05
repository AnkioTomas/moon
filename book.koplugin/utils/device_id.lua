--[[--
设备标识：存在 KOReader 全局设置 device_id 而非本插件配置里，
多源共用同一设备身份，且卸载插件后仍稳定。

@module koplugin.book.utils.device_id
--]]

local DeviceId = {}

--- 取设备标识，没有就生成一个并立即落盘。
---@return string
function DeviceId.ensure()
    local id = G_reader_settings:readSetting("device_id")
    if type(id) == "string" and id ~= "" then return id end
    local rand = require("utils.random").hex(4)
    id = string.format("book-%s%08x", rand, os.time() % 0xffffffff)
    G_reader_settings:saveSetting("device_id", id)
    return id
end

return DeviceId
