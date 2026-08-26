--[[-- 前光开关快捷动作。
@module koplugin.book.ui.panel.actions.desktop.frontlight
--]]

local Device = require("device")
local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "frontlight",
    title = _("前光开关"),
    icon = "light_mode",
    scope = "desktop",
    event = "ToggleFrontlight",
    --- 仅在前光硬件可用的设备上显示。
    ---@return boolean
    available = function()
        return Device:hasFrontlight()
    end,
}
