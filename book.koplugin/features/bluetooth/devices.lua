--[[--
蓝牙窗口：开关、已配对设备（点按连接 / 断开）、扫描配对新设备。

  +-------------------------------+
  | 蓝牙                      [×] |
  | 蓝牙                   已开启 |   点按开 / 关
  | BLE-M3                 已连接 |   点按断开
  | Joy-Con (R)            未连接 |   点按连接
  | 扫描并配对新设备              |
  +-------------------------------+

内容跟着 Bluetooth.watch 刷新；同一时间只跑一个操作，进行中的那行显示「处理中…」。

@module koplugin.book.features.bluetooth.devices
--]]

require("l10n").apply()

local Bluetooth = require("features.bluetooth")
local List = require("ui.themes.widgets.list")
local ProgressDialog = require("ui.themes.widgets.progress_dialog")
local Toast = require("ui.themes.widgets.toast")
local T = require("ffi/util").template
local _ = require("gettext")

local Devices = {}

---@param text string
local function toast(text)
    Toast:new{ text = text, timeout = 3 }:show()
end

--- 开 / 关蓝牙，结果用提示告知。
---@param on boolean
function Devices.setEnabled(on)
    local waiting = ProgressDialog:new{
        title = _("蓝牙"), text = on and _("正在打开蓝牙…") or _("正在关闭蓝牙…"), dismissable = false,
    }
    waiting:show()
    Bluetooth.setEnabled(on, function(ok, err)
        waiting:close()
        toast(ok and (on and _("蓝牙已打开") or _("蓝牙已关闭")) or tostring(err))
    end)
end

--- 快捷开关：先读一次真实状态再翻转，缓存可能是旧的或还没读过。
function Devices.toggle()
    Bluetooth.refresh(function(st)
        Devices.setEnabled(st.state ~= "on")
    end)
end

--- 配对；设备要先进入配对模式。
---@param dev BookBluetoothDevice
function Devices.pair(dev)
    local name = Bluetooth.name(dev)
    local waiting = ProgressDialog:new{
        title = name, text = _("正在配对，请让设备保持配对模式"), dismissable = false,
    }
    waiting:show()
    Bluetooth.pair(dev, function(ok, err)
        waiting:close()
        toast(ok and T(_("已配对 %1"), name) or T(_("配对失败：%1"), tostring(err)))
    end)
end

--- 扫描附近设备，点按即配对。关窗停止轮询。
function Devices.scan()
    ---@param devices BookBluetoothDevice[]
    ---@param scanning boolean
    ---@return table[]
    local function items(devices, scanning)
        local out = {}
        for _idx, dev in ipairs(devices) do
            out[#out + 1] = {
                text = Bluetooth.name(dev),
                icon = "bluetooth",
                mandatory = (dev.protocol or "ble"):upper(),
                callback = function() Devices.pair(dev) end,
            }
        end
        if #out == 0 then
            out[1] = { text = scanning and _("正在扫描…") or _("没有发现设备，请让设备进入配对模式后重试"), enabled = false }
        end
        return out
    end
    local handle
    local list = List:new{
        title = _("扫描蓝牙设备"),
        items = items({}, true),
        close_callback = function() handle.cancel() end,
    }
    list:show()
    handle = Bluetooth.scan(function(devices)
        list:setItems(items(devices, true))
    end, function(devices, err)
        if err then toast(T(_("扫描失败：%1"), tostring(err))) end
        list:setItems(items(devices or {}, false))
    end)
end

function Devices.show()
    local list, watch, render
    ---@type string|nil 进行中的操作："power" 或设备地址
    local busy

    ---@param key string
    ---@param idle string
    ---@return string
    local function state(key, idle)
        return busy == key and _("处理中…") or idle
    end

    --- 同一时间只跑一个操作；完成后出错才提示，状态由 watch 刷新。
    ---@param key string
    ---@param fn fun(done: fun(ok: boolean, err: any))
    local function run(key, fn)
        if busy then return end
        busy = key
        render()
        fn(function(ok, err)
            busy = nil
            if not ok then toast(tostring(err)) end
            render()
        end)
    end

    ---@return table[]
    local function items()
        local st = Bluetooth.current()
        local on = st ~= nil and st.state == "on"
        local out = { {
            text = _("蓝牙"),
            icon = on and "bluetooth" or "bluetooth_disabled",
            mandatory = state("power", not st and _("读取中…") or (on and _("已开启") or _("已关闭"))),
            keep_open = true,
            callback = function() run("power", function(done) Bluetooth.setEnabled(not on, done) end) end,
        } }
        if not on then return out end
        ---@cast st BookBluetoothStatus
        for _idx, dev in ipairs(st.devices) do
            local connected = Bluetooth.isConnected(st, dev.address)
            out[#out + 1] = {
                text = Bluetooth.name(dev),
                icon = connected and "bluetooth_connected" or "bluetooth",
                mandatory = state(dev.address, connected and _("已连接") or _("未连接")),
                keep_open = true,
                callback = function()
                    run(dev.address, function(done) Bluetooth.setConnected(dev, not connected, done) end)
                end,
            }
        end
        out[#out + 1] = { text = _("扫描并配对新设备"), icon = "bluetooth_searching", keep_open = true, callback = Devices.scan }
        return out
    end

    render = function()
        if list then list:setItems(items()) end
    end
    list = List:new{
        title = _("蓝牙"),
        items = items(),
        close_callback = function()
            list = nil
            watch.cancel()
        end,
    }
    list:show()
    watch = Bluetooth.watch(render)
end

return Devices
