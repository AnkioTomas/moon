--[[--
把同步蓝牙原语（kindle.lua / kobo.lua：available/status/setEnabled/connect/disconnect/bond/triggerScan/discovered）
适配成 khp.lua 的异步后端接口。两个系统后端的区别只在原语，等待与轮询流程完全一样。

原语里的开关 / 连接命令会阻塞几秒，晚一拍执行让进度窗先画出来。

@module koplugin.book.features.bluetooth.sync
--]]

require("l10n").apply()

local UIManager = require("ui/uimanager")
local _ = require("gettext")

local WAIT_SECONDS = 15
local STEP_SECONDS = 2
local SCAN_STEPS = 15

local Sync = {}

---@param raw table 同步原语
---@return table 异步后端
function Sync.wrap(raw)
    local Backend = { available = raw.available }

    ---@param cb fun(st: BookBluetoothStatus)
    function Backend.status(cb)
        cb(raw.status())
    end

    --- 每秒读一次状态，直到 pred 成立或 seconds 秒用完。
    local function waitFor(pred, seconds, cb)
        if pred(raw.status()) then return cb(true) end
        if seconds <= 0 then return cb(false) end
        UIManager:scheduleIn(1, function() waitFor(pred, seconds - 1, cb) end)
    end

    local function connected(st, address)
        for _idx, conn in ipairs(st.connections) do
            if conn.address:upper() == address:upper() then return true end
        end
        return false
    end

    function Backend.setEnabled(on, cb)
        UIManager:scheduleIn(0.3, function()
            if (raw.status().state == "on") == on then return cb(true) end
            if not raw.setEnabled(on) then return cb(false, _("无法控制系统蓝牙")) end
            waitFor(function(s) return (s.state == "on") == on end, WAIT_SECONDS, function(done)
                cb(done, not done and _("蓝牙状态没有变化") or nil)
            end)
        end)
    end

    function Backend.setConnected(dev, connect, cb)
        UIManager:scheduleIn(0.3, function()
            local sent = connect and raw.connect(dev.address) or (not connect and raw.disconnect(dev.address))
            if not sent then return cb(false, _("无法控制系统蓝牙")) end
            waitFor(function(s) return connected(s, dev.address) == connect end, WAIT_SECONDS, function(done)
                cb(done, not done and (connect and _("连接超时，请确认设备已开机并在附近") or _("断开超时")) or nil)
            end)
        end)
    end

    function Backend.scan(on_update, on_done)
        if not raw.triggerScan() then
            on_done(nil, _("无法控制系统蓝牙"))
            return { cancel = function() end }
        end
        local left = SCAN_STEPS
        local tick
        tick = function()
            left = left - 1
            local devices = raw.discovered()
            if left <= 0 then return on_done(devices) end
            on_update(devices)
            UIManager:scheduleIn(STEP_SECONDS, tick)
        end
        UIManager:scheduleIn(STEP_SECONDS, tick)
        return { cancel = function() UIManager:unschedule(tick) end }
    end

    function Backend.pair(dev, cb)
        local waiting = true
        UIManager:scheduleIn(0.3, function()
            if not waiting then return end
            if not raw.bond(dev.address) then return cb(false, _("无法控制系统蓝牙")) end
            waitFor(function(s)
                for _idx, paired in ipairs(s.devices) do
                    if paired.address == dev.address then return true end
                end
                return false
            end, WAIT_SECONDS * 2, function(done)
                if not waiting then return end
                if done then raw.connect(dev.address) end
                cb(done, not done and _("配对超时") or nil)
            end)
        end)
        return { cancel = function() waiting = false end }
    end

    return Backend
end

return Sync
