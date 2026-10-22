--[[--
蓝牙 Kindle 后端：Kindle 自带蓝牙服务 com.lab126.btfd（lipc）。

国产蓝牙翻页器按原生设备配对，翻页键由系统接管；这里只负责开关、扫描、配对、连接。
全部是本机 lipc 调用（毫秒级，同步）。没有 kindle-hid-passthrough 守护进程时才用它，
守护进程会接管蓝牙芯片，两者不能同时用。

btfd 属性：BTstate(int,r) / BTenable(str,w "1:2"|"0:2") / triggerBTscan(int,w) /
Bond、Connect、Disconnect(str,w 地址) / ListPaired、ListConnected、ListDiscovered(hash,r)。
哈希行的字段名没有文档，按常见键名取。

@module koplugin.book.features.bluetooth.kindle
--]]

local SERVICE = "com.lab126.btfd"
local ADDRESS_KEYS = { "address", "bdaddr", "bdAddr", "mac", "deviceAddress", "addr", "id" }
local NAME_KEYS = { "name", "deviceName", "friendlyName", "displayName" }

local Native = {}

---@type boolean|nil
local usable

--- 打开一个 lipc 句柄执行 fn 再关闭；库不存在返回 nil。
---@generic T
---@param fn fun(handle: table): T
---@return T|nil
local function withLipc(fn)
    local ok, lipc = pcall(require, "liblipclua")
    if not ok then return nil end
    local handle = lipc.init("com.github.koreader.moon.bluetooth")
    if not handle then return nil end
    local done, result = pcall(fn, handle)
    handle:close()
    if not done then return nil end
    return result
end

---@return integer|nil
local function btState()
    return withLipc(function(h) return h:get_int_property(SERVICE, "BTstate") end)
end

--- 是 Kindle 且 btfd 能读到状态。结果缓存。
---@return boolean
function Native.available()
    if usable == nil then
        usable = require("device"):isKindle() and type(btState()) == "number"
    end
    return usable
end

---@param value any
---@return string|nil
local function normalize(value)
    if type(value) ~= "string" then return nil end
    value = value:gsub("-", ":"):upper()
    return value:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") and value or nil
end

---@param row table
---@return BookBluetoothDevice|nil
local function toDevice(row)
    local address
    for _idx, key in ipairs(ADDRESS_KEYS) do
        address = normalize(row[key])
        if address then break end
    end
    if not address then
        for _key, value in pairs(row) do
            address = normalize(tostring(value))
            if address then break end
        end
    end
    if not address then return nil end
    local name
    for _idx, key in ipairs(NAME_KEYS) do
        if type(row[key]) == "string" and row[key] ~= "" then name = row[key] break end
    end
    return { address = address, protocol = "", name = name }
end

---@param prop string ListPaired / ListConnected / ListDiscovered
---@return BookBluetoothDevice[]
local function list(prop)
    local ok, lipc = pcall(require, "libopenlipclua")
    if not ok then return {} end
    local handle = lipc.open_no_name()
    if not handle then return {} end
    local input = handle:new_hasharray()
    local done, result = pcall(handle.access_hash_property, handle, SERVICE, prop, input)
    input:destroy()
    local devices = {}
    if done and result then
        for _idx, row in ipairs(result:to_table() or {}) do
            devices[#devices + 1] = toDevice(row)
        end
        result:destroy()
    end
    handle:close()
    return devices
end

--- 当前蓝牙状态；只有 on / stopped（btfd 常驻，不存在 off）。
---@return BookBluetoothStatus
function Native.status()
    local on = (btState() or 0) ~= 0
    return {
        state = on and "on" or "stopped",
        devices = on and list("ListPaired") or {},
        connections = on and list("ListConnected") or {},
    }
end

---@param prop string
---@param value string
---@return boolean
local function setString(prop, value)
    return withLipc(function(h) h:set_string_property(SERVICE, prop, value) return true end) == true
end

---@param on boolean
---@return boolean
function Native.setEnabled(on)
    return setString("BTenable", on and "1:2" or "0:2")
end

---@param address string
---@return boolean
function Native.connect(address)
    return setString("Connect", address)
end

---@param address string
---@return boolean
function Native.disconnect(address)
    return setString("Disconnect", address)
end

---@param address string
---@return boolean
function Native.bond(address)
    return setString("Bond", address)
end

---@return boolean
function Native.triggerScan()
    return withLipc(function(h) h:set_int_property(SERVICE, "triggerBTscan", 1) return true end) == true
end

---@return BookBluetoothDevice[]
function Native.discovered()
    return list("ListDiscovered")
end

return Native
