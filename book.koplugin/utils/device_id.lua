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
    -- 随机段必须来自 urandom：math.random 未播种时 LuaJIT 每次启动都是同一序列，
    -- 同一天开机的两台设备会拿到完全相同的 device_id，云端按设备隔离的数据会互相踩。
    local rand
    local f = io.open("/dev/urandom", "rb")
    if f then
        rand = f:read(4)
        f:close()
    end
    if type(rand) == "string" and #rand == 4 then
        rand = rand:gsub(".", function(ch) return string.format("%02x", ch:byte()) end)
    else
        math.randomseed(os.time() + tonumber(tostring({}):match("0x(%x+)") or "0", 16))
        rand = string.format("%08x", math.floor(math.random() * 0xffffffff))
    end
    id = string.format("book-%s%08x", rand, os.time() % 0xffffffff)
    G_reader_settings:saveSetting("device_id", id)
    return id
end

return DeviceId
