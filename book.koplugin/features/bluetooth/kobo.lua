--[[--
蓝牙 Kobo 后端，做法参照 onatbas/bluetooth.koplugin：

  i.MX6（Clara 2E / Libra 2 等）  insmod 电源模块 + uhid.ko、hciattach、bluetoothctl
  MTK（Clara BW/Colour、Libra Colour、Elipsa 2E）  D-Bus 服务 com.kobo.mtk.bluedroid

和 kindle.lua（Kindle btfd）同一组同步函数。全部是本机命令，开关要几秒（会阻塞界面，调用方先弹进度窗）。
连上后蓝牙 HID 设备在 /sys/class/input 里是 uhid 设备，要手动 Device.input:open 才收得到按键。

没有现成方案的假设（没有 Kobo 真机验证）：
- i.MX6 的 uhid.ko 不是 Kobo 自带内核模块，找 /sys/module/uhid 或已装的 bluetooth.koplugin/uhid/uhid.ko，
  都没有就不 insmod，设备能连但没有按键输入。
- 命令输出格式按 BlueZ 5.x 与参考插件。

@module koplugin.book.features.bluetooth.kobo
--]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("utils.log")

local MTK_MODELS = { Kobo_condor = true, Kobo_monza = true, Kobo_spaBW = true, Kobo_spaColour = true }
local DEST = "com.kobo.mtk.bluedroid"
local ADAPTER = "/org/bluez/hci0"
local INPUT_DIR = "/sys/class/input"

local Kobo = {}

---@type boolean|nil
local usable
---@type "mtk"|"imx6"|nil
local kind
---@type table<string, integer> 已打开的输入设备路径 → inode
local opened = {}

--- 执行 shell 命令取输出；系统有 timeout 就限时。
---@param cmd string
---@param seconds integer
---@return string
local function run(cmd, seconds)
    local line = string.format(
        "if command -v timeout >/dev/null 2>&1; then timeout %d %s; else %s; fi 2>&1", seconds, cmd, cmd)
    local handle = io.popen(line)
    if not handle then return "" end
    local out = handle:read("*a")
    handle:close()
    logger.info("bluetooth kobo:", cmd, "->", (out:gsub("%s+$", ""):sub(1, 300)))
    return out
end

---@param path string
---@return boolean
local function exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

--- 是 Kobo 且有可用的蓝牙栈。结果缓存。
---@return boolean
function Kobo.available()
    if usable == nil then
        local Device = require("device")
        usable = false
        if Device:isKobo() then
            if MTK_MODELS[Device.model] then
                kind = "mtk"
            elseif exists("/sbin/hciattach") or exists("/sbin/rtk_hciattach") then
                kind = "imx6"
            end
            usable = kind ~= nil
        end
    end
    return usable
end

---@param address string
---@return string
local function devicePath(address)
    return ADAPTER .. "/dev_" .. address:gsub(":", "_")
end

---@param path string
---@param method string
---@param ... string
---@return boolean
local function dbusCall(path, method, ...)
    local args = { ... }
    local cmd = string.format("dbus-send --system --print-reply --dest=%s %s %s %s >/dev/null 2>&1",
        DEST, path, method, table.concat(args, " "))
    local ok = os.execute(cmd)
    return ok == true or ok == 0
end

--- 读 D-Bus 对象表里的设备。
---@return { address: string, name: string, paired: boolean, connected: boolean }[]
local function mtkDevices()
    local out = run("dbus-send --system --print-reply --dest=" .. DEST
        .. " / org.freedesktop.DBus.ObjectManager.GetManagedObjects", 5)
    local devices, cur, prop = {}, nil, nil
    for line in out:gmatch("[^\r\n]+") do
        local mac = line:match('object path "/org/bluez/hci0/dev_([%w_]+)"')
        if mac then
            cur = { address = mac:gsub("_", ":"), name = "", paired = false, connected = false }
            devices[#devices + 1] = cur
            prop = nil
        elseif cur then
            prop = line:match('string "(%a+)"') or prop
            if prop == "Name" then
                local v = line:match('variant%s+string "([^"]*)"')
                if v then cur.name, prop = v, nil end
            elseif prop == "Paired" or prop == "Connected" then
                local v = line:match("variant%s+boolean (%a+)")
                if v then cur[prop:lower()], prop = v == "true", nil end
            end
        end
    end
    return devices
end

---@return boolean
local function isOn()
    if kind == "mtk" then
        return run("dbus-send --system --print-reply --dest=" .. DEST .. " " .. ADAPTER
            .. " org.freedesktop.DBus.Properties.Get string:org.bluez.Adapter1 string:Powered", 3)
            :find("boolean true", 1, true) ~= nil
    end
    return run("hciconfig hci0", 3):find("UP RUNNING", 1, true) ~= nil
end

--- 找 uhid 输入设备并交给 KOReader 读。重连后节点会换，按 inode 重开。
local function attachInput()
    local Device = require("device")
    for entry in lfs.dir(INPUT_DIR) do
        local node = entry:match("^event%d+$")
        local target = node and lfs.symlinkattributes(INPUT_DIR .. "/" .. node, "target")
        if target and target:find("uhid", 1, true) then
            local path = "/dev/input/" .. node
            local ino = lfs.attributes(path, "ino")
            if ino and opened[path] ~= ino then
                pcall(Device.input.close, Device.input, path)
                Device.input:open(path)
                opened[path] = ino
                logger.info("bluetooth kobo: 打开输入设备", path)
            end
        end
    end
end

---@param line string
---@return BookBluetoothDevice|nil
local function parseDevice(line)
    local address, name = line:match("^Device%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s*(.*)$")
    if not address then return nil end
    return { address = address:upper(), protocol = "", name = name ~= "" and name or nil }
end

---@param out string
---@return BookBluetoothDevice[]
local function parseList(out)
    local devices = {}
    for line in out:gmatch("[^\r\n]+") do
        devices[#devices + 1] = parseDevice(line)
    end
    return devices
end

---@return BookBluetoothStatus
function Kobo.status()
    if not isOn() then return { state = "stopped", devices = {}, connections = {} } end
    local devices, connections = {}, {}
    if kind == "mtk" then
        for _idx, dev in ipairs(mtkDevices()) do
            if dev.paired then
                local item = { address = dev.address:upper(), protocol = "", name = dev.name ~= "" and dev.name or nil }
                devices[#devices + 1] = item
                if dev.connected then connections[#connections + 1] = item end
            end
        end
    else
        devices = parseList(run("bluetoothctl paired-devices", 3))
        for _idx, dev in ipairs(devices) do
            if run("bluetoothctl info " .. dev.address, 3):find("Connected: yes", 1, true) then
                connections[#connections + 1] = dev
            end
        end
    end
    if #connections > 0 then attachInput() end
    return { state = "on", devices = devices, connections = connections }
end

---@return string|nil
local function findDriver()
    local out = run("ls /drivers/*/wifi/sdio_bt_pwr.ko", 3)
    return out:match("(/drivers/%S+sdio_bt_pwr%.ko)")
end

---@return string|nil
local function findUhid()
    if exists("/sys/module/uhid") then return nil end
    local base = lfs.currentdir() .. "/plugins/bluetooth.koplugin/uhid/uhid.ko"
    return exists(base) and base or nil
end

---@param on boolean
---@return boolean
function Kobo.setEnabled(on)
    if kind == "mtk" then
        if on then
            dbusCall("/", "com.kobo.bluetooth.BluedroidManager1.On")
            dbusCall(ADAPTER, "org.freedesktop.DBus.Properties.Set",
                "string:org.bluez.Adapter1", "string:Powered", "variant:boolean:true")
        else
            dbusCall(ADAPTER, "org.freedesktop.DBus.Properties.Set",
                "string:org.bluez.Adapter1", "string:Powered", "variant:boolean:false")
            dbusCall("/", "com.kobo.bluetooth.BluedroidManager1.Off")
        end
        return isOn() == on
    end
    local rtk = exists("/sbin/rtk_hciattach")
    if on then
        local driver = findDriver()
        if driver then run("insmod " .. driver, 5) end
        local uhid = findUhid()
        if uhid then run("insmod " .. uhid, 5) end
        run(rtk and "/sbin/rtk_hciattach -s 115200 ttymxc1 rtk_h5"
            or "/sbin/hciattach -p ttymxc1 any 1500000 flow -t 20", 30)
        -- 触发 D-Bus 激活 bluetoothd
        run("dbus-send --system --dest=org.bluez / org.freedesktop.DBus.ObjectManager.GetManagedObjects", 5)
        run("hciconfig hci0 up", 5)
    else
        run("hciconfig hci0 down", 5)
        run(rtk and "pkill rtk_hciattach" or "pkill hciattach", 3)
        run("pkill bluetoothd", 3)
        run("rmmod sdio_bt_pwr", 3)
        run("rmmod uhid", 3)
        opened = {}
    end
    return isOn() == on
end

---@param address string
---@return boolean
function Kobo.connect(address)
    local ok
    if kind == "mtk" then
        ok = dbusCall(devicePath(address), "org.bluez.Device1.Connect")
    else
        ok = run("bluetoothctl connect " .. address, 8):find("Connection successful", 1, true) ~= nil
    end
    if ok then attachInput() end
    return ok
end

---@param address string
---@return boolean
function Kobo.disconnect(address)
    if kind == "mtk" then return dbusCall(devicePath(address), "org.bluez.Device1.Disconnect") end
    return run("bluetoothctl disconnect " .. address, 6):find("Successful disconnected", 1, true) ~= nil
end

--- 配对并信任（信任后设备重连不用再确认）。
---@param address string
---@return boolean
function Kobo.bond(address)
    if kind == "mtk" then
        local path = devicePath(address)
        local ok = dbusCall(path, "org.bluez.Device1.Pair")
        dbusCall(path, "org.freedesktop.DBus.Properties.Set",
            "string:org.bluez.Device1", "string:Trusted", "variant:boolean:true")
        return ok
    end
    local out = run("bluetoothctl pair " .. address, 20)
    -- 已配对的设备再 pair 会报 AlreadyExists，状态已满足，不算失败。
    local paired = out:find("Pairing successful", 1, true) ~= nil or out:find("AlreadyExists", 1, true) ~= nil
    run("bluetoothctl trust " .. address, 5)
    return paired
end

---@return boolean
function Kobo.triggerScan()
    if kind == "mtk" then return dbusCall(ADAPTER, "org.bluez.Adapter1.StartDiscovery") end
    os.execute("(timeout 30 bluetoothctl scan on >/dev/null 2>&1 &)")
    return true
end

---@return BookBluetoothDevice[]
function Kobo.discovered()
    if kind == "mtk" then
        local devices = {}
        for _idx, dev in ipairs(mtkDevices()) do
            devices[#devices + 1] = { address = dev.address:upper(), protocol = "", name = dev.name ~= "" and dev.name or nil }
        end
        return devices
    end
    return parseList(run("bluetoothctl devices", 3))
end

return Kobo
