--[[-- Wi-Fi 快捷动作。
@module koplugin.book.features.panel.actions.desktop.wifi
--]]

local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "wifi",
    title = _("Wi-Fi"),
    icon = "wifi",
    scope = "desktop",
    event = "ToggleWifi",
    keep_open = true,
    refresh_delay = 1,
    --- 设备支持 Wi-Fi 开关时显示。
    ---@return boolean
    available = function()
        return Device:hasWifiToggle()
    end,
    --- 读取当前 Wi-Fi 状态，用于按钮激活态。
    ---@return boolean
    active = function()
        return NetworkMgr:isWifiOn()
    end,
    --- 长按：Android 打开系统 Wi-Fi 设置，其余设备走 KOReader 原生长按路径，开着也弹网络列表。
    hold = function()
        if Device:isAndroid() then
            NetworkMgr:openSettings()
        else
            NetworkMgr:toggleWifiOn(nil, true, true)
        end
    end,
}
