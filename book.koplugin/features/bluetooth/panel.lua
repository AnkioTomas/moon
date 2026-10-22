--[[--
蓝牙的桌面快捷面板开关：开关蓝牙、打开蓝牙设备窗口。没有蓝牙后端（kindle-hid-passthrough 或系统蓝牙）不出现。

@module koplugin.book.features.bluetooth.panel
--]]

require("l10n").apply()

local _ = require("gettext")

local Panel = {}

---@return boolean
local function installed()
    return require("features.bluetooth").installed()
end

---@return BookQuickPanelAction[]
function Panel.actions()
    return {
        {
            id = "bluetooth",
            title = _("蓝牙"),
            icon = "bluetooth_disabled",
            active_icon = "bluetooth",
            scope = "desktop",
            available = installed,
            ---@return boolean
            active = function()
                local st = require("features.bluetooth").current()
                return st ~= nil and st.state == "on"
            end,
            run = function()
                require("features.bluetooth.devices").toggle()
            end,
        },
        {
            id = "bluetooth_devices",
            title = _("蓝牙设备"),
            icon = "settings_bluetooth",
            scope = "desktop",
            available = installed,
            run = function()
                require("features.bluetooth.devices").show()
            end,
        },
    }
end

return Panel
