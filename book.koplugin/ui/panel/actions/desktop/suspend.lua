--[[-- 休眠快捷动作。
@module koplugin.book.ui.panel.actions.desktop.suspend
--]]

local Device = require("device")
local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "suspend",
    title = _("休眠"),
    icon = "mode_standby",
    scope = "desktop",
    event = "RequestSuspend",
    --- 仅设备支持休眠时显示。
    ---@return boolean
    available = function()
        return Device:canSuspend()
    end,
}
