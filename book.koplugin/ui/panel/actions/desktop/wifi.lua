--[[-- Wi-Fi 快捷动作。
@module koplugin.book.ui.panel.actions.desktop.wifi
--]]

local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")

---@class BookQuickPanelAction
return {
    id = "wifi",
    title = _("Wi-Fi"),
    icon = "signal_wifi_4_bar",
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
}
