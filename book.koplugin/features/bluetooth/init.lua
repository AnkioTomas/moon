--[[--
蓝牙：对外门面，只管后端选择、状态缓存与订阅轮询。具体后端三选一（按序取第一个可用的）：

  khp.lua     kindle-hid-passthrough 守护进程（HTTP 127.0.0.1:8321），通用 HID 设备
  kindle.lua  Kindle 原生蓝牙服务 btfd（lipc），国产蓝牙翻页器走这条
  kobo.lua    Kobo 系统蓝牙（i.MX6 hciattach / MTK dbus）

守护进程会接管蓝牙芯片，所以排第一。kindle / kobo 是同步原语，经 sync.lua 适配成与 khp 相同的异步接口：
available()、status(cb)、setEnabled(on, cb)、setConnected(dev, connect, cb)、scan(on_update, on_done)、pair(dev, cb)。

Kindle 睡眠 / 关 Wi-Fi 都会把蓝牙射频掐掉：见 on 时记下 wanted（连接表），用户主动关才清。
睡醒（onResume）与 NetworkDisconnected 共用 restore：重新打开并连回。睡眠中不抢跑 Wi-Fi 恢复。

Android 的蓝牙在系统里，KOReader 没有接口；都没有时顶栏项与快捷开关都不出现。

@module koplugin.book.features.bluetooth
--]]

require("l10n").apply()

local UIManager = require("ui/uimanager")
local logger = require("utils.log")

local POLL_SECONDS = 30
-- 关 Wi-Fi 后射频落定再动手；太短会跟还没死的旧状态打架
local WIFI_RESTORE_DELAY = 2

---@class BookBluetoothDevice
---@field address string
---@field protocol string|nil "ble" | "classic"；系统后端为 ""
---@field name string|nil

---@class BookBluetoothStatus
---@field state "off"|"stopped"|"on"
---@field devices BookBluetoothDevice[] 已配对
---@field connections BookBluetoothDevice[] 当前已连接

local Bluetooth = {}

---@type BookBluetoothStatus|nil
local status
---@type fun()[]
local watchers = {}
---@type fun()|nil
local poll_tick
---@type table|false|nil
local chosen

--- 当前后端；没有为 nil。
---@return table|nil
local function backend()
    -- 只记住选中的；「都没有」不记：khp 守护进程可能在 KOReader 之后才起来，记死就得重启才见蓝牙入口。
    -- 重探很便宜：khp 是一次 stat，kindle / kobo 各自缓存探测结果。
    if chosen then return chosen end
    for _idx, name in ipairs({ "khp", "kindle", "kobo" }) do
        local mod = require("features.bluetooth." .. name)
        if mod.available() then
            chosen = name == "khp" and mod or require("features.bluetooth.sync").wrap(mod)
            return chosen
        end
    end
    return nil
end

--- 有可用的蓝牙后端。
---@return boolean
function Bluetooth.installed()
    return backend() ~= nil
end

--- 最近一次读到的状态；还没读过为 nil。
---@return BookBluetoothStatus|nil
function Bluetooth.current()
    return status
end

---@param st BookBluetoothStatus|nil
---@param address string
---@return boolean
function Bluetooth.isConnected(st, address)
    for _idx, conn in ipairs(st and st.connections or {}) do
        if conn.address:upper() == address:upper() then return true end
    end
    return false
end

--- 设备显示名：没名字用地址。
---@param dev BookBluetoothDevice
---@return string
function Bluetooth.name(dev)
    return dev.name or dev.address
end

--- 用户意图：见 on 记下连接表；只有主动关闭才清（睡眠 / Wi-Fi 带崩不记关）。
---@type { connections: BookBluetoothDevice[] }|nil
local wanted
local sleeping = false
--- onSuspend 置位，onResume 消费：FM/Reader 双实例只恢复一次。
local resume_armed = false

---@param st BookBluetoothStatus|nil
local function noteWanted(st)
    if st and st.state == "on" then
        wanted = { connections = { unpack(st.connections or {}) } }
    end
end

--- 读状态更新缓存并通知订阅方。
---@param cb fun(st: BookBluetoothStatus)|nil
function Bluetooth.refresh(cb)
    backend().status(function(st)
        status = st
        noteWanted(st)
        for _idx, fn in ipairs({ unpack(watchers) }) do fn() end
        if cb then cb(st) end
    end)
end

--- 订阅状态变化：有订阅方时每 POLL_SECONDS 读一次 /status，订阅时立即读一次。
---@param cb fun()
---@return CancelHandle
function Bluetooth.watch(cb)
    if not Bluetooth.installed() then return { cancel = function() end } end
    watchers[#watchers + 1] = cb
    if not poll_tick then
        poll_tick = function()
            Bluetooth.refresh()
            UIManager:scheduleIn(POLL_SECONDS, poll_tick)
        end
        poll_tick()
    end
    return {
        cancel = function()
            for i, fn in ipairs(watchers) do
                if fn == cb then table.remove(watchers, i) break end
            end
            if #watchers == 0 and poll_tick then
                UIManager:unschedule(poll_tick)
                poll_tick = nil
            end
        end,
    }
end

--- 动作完成后刷新缓存再回调，订阅方立刻看到新状态。
---@param cb fun(ok: boolean, err: any)
---@return fun(ok: boolean, err: any)
local function refreshed(cb)
    return function(ok, err)
        Bluetooth.refresh(function() cb(ok, err) end)
    end
end

--- 打开 / 关闭蓝牙。主动关闭清掉 wanted，避免关 Wi-Fi 恢复逻辑把用户关的蓝牙又拉起来。
---@param on boolean
---@param cb fun(ok: boolean, err: any)
function Bluetooth.setEnabled(on, cb)
    backend().setEnabled(on, function(ok, err)
        if ok and not on then wanted = nil end
        refreshed(cb)(ok, err)
    end)
end

--- 连接 / 断开已配对设备，等到连接表变化为止。
---@param dev BookBluetoothDevice
---@param connect boolean
---@param cb fun(ok: boolean, err: any)
function Bluetooth.setConnected(dev, connect, cb)
    backend().setConnected(dev, connect, refreshed(cb))
end

--- 扫描附近的设备。扫描中 on_update(devices) 多次，结束 on_done(devices, err) 一次。
---@param on_update fun(devices: BookBluetoothDevice[])
---@param on_done fun(devices: BookBluetoothDevice[]|nil, err: any)
---@return CancelHandle
function Bluetooth.scan(on_update, on_done)
    return backend().scan(on_update, on_done)
end

--- 配对；成功后自动连接。
---@param dev BookBluetoothDevice
---@param cb fun(ok: boolean, err: any)
---@return CancelHandle
function Bluetooth.pair(dev, cb)
    return backend().pair(dev, refreshed(cb))
end

--- 按 wanted 重新打开并连回（睡醒 / Wi-Fi 带崩共用）。setEnabled 已 refresh，直接读缓存。
---@param tag string 日志标签 resume / wifi
local function restore(tag)
    if not wanted or not Bluetooth.installed() then return end
    local conns = wanted.connections
    Bluetooth.setEnabled(true, function(ok, err)
        if not ok then
            logger.warn("book.bluetooth " .. tag .. " restore failed:", err)
            return
        end
        if #conns == 0 then return end
        local st = Bluetooth.current()
        for _idx, dev in ipairs(conns) do
            if not Bluetooth.isConnected(st, dev.address) then
                Bluetooth.setConnected(dev, true, function(done, conn_err)
                    if not done then
                        logger.warn("book.bluetooth " .. tag .. " reconnect failed:",
                            dev.address, conn_err)
                    end
                end)
            end
        end
    end)
end

--- 睡眠前：武装一次唤醒恢复；顺手 refresh，射频还在时把 wanted 刷新到最新连接表。
function Bluetooth.onSuspend()
    if not Bluetooth.installed() then return end
    sleeping = true
    resume_armed = wanted ~= nil
    Bluetooth.refresh()
end

--- 唤醒：只跑一次（双实例），按 wanted 拉起。
function Bluetooth.onResume()
    sleeping = false
    if not resume_armed then return end
    resume_armed = false
    restore("resume")
end

--- 关 Wi-Fi 常顺带掐蓝牙：延迟后按 wanted 拉起（已 on 时 setEnabled 是空操作）。
Bluetooth.events = {
    NetworkDisconnected = function(_plugin)
        if sleeping or not wanted or not Bluetooth.installed() then return end
        UIManager:scheduleIn(WIFI_RESTORE_DELAY, function()
            if sleeping or not wanted then return end
            restore("wifi")
        end)
    end,
}

--- 顶栏读数：还没读过（没装就不会读）不显示；连上一台显示名字（没名字只显示图标），多台显示台数。
---@return string|nil text
---@return string|nil icon
function Bluetooth.topbar()
    if not status then return nil end
    if status.state ~= "on" then return nil, "bluetooth_disabled" end
    local conns = status.connections
    if #conns == 0 then return nil, "bluetooth" end
    if #conns > 1 then return tostring(#conns), "bluetooth_connected" end
    -- 顶栏只留前 4 个字（按 UTF-8 字符数）
    local name = conns[1].name
    if not name then return nil, "bluetooth_connected" end
    return name:match("^" .. require("utils.text").UTF8_CHAR:rep(4)) or name, "bluetooth_connected"
end

return Bluetooth
