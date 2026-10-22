--[[--
features.bluetooth Kobo 后端（命令输出打桩，无设备）：i.MX6 的 bluetoothctl 与 MTK 的 D-Bus 解析、开关与连接命令、uhid 输入设备打开。
@module tests.features.bluetooth.kobo_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field, need-check-nil

-- 文件系统：files[path] = true 存在；targets[path] = sysfs 符号链接目标；inodes[path]。
local files, targets, inodes = {}, {}, {}
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, name)
            if name == "ino" then return inodes[path] end
            return files[path] and "file" or nil
        end,
        symlinkattributes = function(path) return targets[path] end,
        dir = function()
            local list = { "event1", "event2" }
            local i = 0
            return function() i = i + 1 return list[i] end
        end,
        currentdir = function() return "/koreader" end,
    }
end

local Assert = require("support.assert")

package.preload["device"] = nil
local model = "Kobo_io"
local opens = {}
package.preload["device"] = function()
    return {
        isKobo = function() return true end,
        model = model,
        input = {
            open = function(_self, path) opens[#opens + 1] = "open " .. path end,
            close = function(_self, path) opens[#opens + 1] = "close " .. path end,
        },
    }
end

-- 命令 → 输出：按子串匹配，记录执行过的命令。
local outputs, cmds = {}, {}
local real_popen, real_execute = io.popen, os.execute
io.popen = function(cmd)
    cmds[#cmds + 1] = cmd
    local out = ""
    for needle, text in pairs(outputs) do
        if cmd:find(needle, 1, true) then out = text break end
    end
    return { read = function() return out end, close = function() end }
end
os.execute = function(cmd)
    cmds[#cmds + 1] = cmd
    return 0
end

local function ran(needle)
    for _idx, cmd in ipairs(cmds) do
        if cmd:find(needle, 1, true) then return true end
    end
    return false
end

local function fresh()
    package.loaded["features.bluetooth.kobo"] = nil
    cmds, opens, outputs = {}, {}, {}
    return require("features.bluetooth.kobo")
end

-- 不是 Kobo 就不可用；没有 hciattach 的 i.MX6 也不可用。
do
    files = {}
    local Kobo = fresh()
    Assert.is_false(Kobo.available(), "没有蓝牙栈")
end

-- i.MX6：hci0 起来才算 on；已配对来自 paired-devices，连接状态来自 info；有连接才打开 uhid 输入设备。
do
    files = { ["/sbin/hciattach"] = true }
    targets["/sys/class/input/event2"] = "../../devices/virtual/misc/uhid/0005/input/input7/event2"
    targets["/sys/class/input/event1"] = "../../devices/platform/pwrkey/input/input1/event1"
    inodes["/dev/input/event2"] = 7
    local Kobo = fresh()
    Assert.is_true(Kobo.available())

    outputs["hciconfig hci0"] = "hci0: UP RUNNING"
    outputs["paired-devices"] = "Device E4:17:D8:7D:3D:69 8BitDo Micro gamepad\n"
    outputs["info E4:17:D8:7D:3D:69"] = "Connected: yes"
    local st = Kobo.status()
    Assert.eq(st.state, "on")
    Assert.eq(st.devices[1].address, "E4:17:D8:7D:3D:69")
    Assert.eq(st.devices[1].name, "8BitDo Micro gamepad")
    Assert.len(st.connections, 1)
    Assert.eq(table.concat(opens, ","), "close /dev/input/event2,open /dev/input/event2")

    Kobo.status()
    Assert.len(opens, 2, "同一个 inode 不重复打开")

    outputs["hciconfig hci0"] = "hci0: DOWN"
    Assert.eq(Kobo.status().state, "stopped")

    outputs["connect E4"] = "Connection successful"
    Assert.is_true(Kobo.connect("E4:17:D8:7D:3D:69"))
    outputs["connect E4"] = "Failed to connect"
    Assert.is_false(Kobo.connect("E4:17:D8:7D:3D:69"))
end

-- i.MX6 开关命令序列：Libra 2 用 rtk_hciattach。
do
    files = { ["/sbin/rtk_hciattach"] = true }
    local Kobo = fresh()
    outputs["ls /drivers"] = "/drivers/mx6sll-ntx/wifi/sdio_bt_pwr.ko\n"
    outputs["hciconfig hci0"] = "hci0: UP RUNNING"
    Assert.is_true(Kobo.setEnabled(true))
    Assert.is_true(ran("insmod /drivers/mx6sll-ntx/wifi/sdio_bt_pwr.ko"))
    Assert.is_true(ran("/sbin/rtk_hciattach"))
    Assert.is_true(ran("hciconfig hci0 up"))

    outputs["hciconfig hci0"] = "hci0: DOWN"
    Assert.is_true(Kobo.setEnabled(false))
    Assert.is_true(ran("pkill rtk_hciattach"))
    Assert.is_true(ran("rmmod sdio_bt_pwr"))
end

-- MTK：D-Bus 对象表解析（只取已配对）、连接走设备对象路径。
do
    model = "Kobo_monza"
    files = {}
    package.loaded["device"] = nil
    local Kobo = fresh()
    Assert.is_true(Kobo.available())

    outputs["Properties.Get"] = "variant boolean true"
    outputs["GetManagedObjects"] = table.concat({
        'dict entry( object path "/org/bluez/hci0/dev_E4_17_D8_7D_3D_69"',
        'string "Name"', 'variant string "BLE-M3"',
        'string "Paired"', 'variant boolean true',
        'string "Connected"', 'variant boolean false',
        'dict entry( object path "/org/bluez/hci0/dev_11_22_33_44_55_66"',
        'string "Paired"', 'variant boolean false',
    }, "\n")
    local st = Kobo.status()
    Assert.eq(st.state, "on")
    Assert.len(st.devices, 1)
    Assert.eq(st.devices[1].name, "BLE-M3")
    Assert.len(st.connections, 0)
    Assert.len(Kobo.discovered(), 2, "扫描列表含未配对设备")

    Assert.is_true(Kobo.connect("E4:17:D8:7D:3D:69"))
    Assert.is_true(ran("/org/bluez/hci0/dev_E4_17_D8_7D_3D_69 org.bluez.Device1.Connect"))
end

io.popen, os.execute = real_popen, real_execute
