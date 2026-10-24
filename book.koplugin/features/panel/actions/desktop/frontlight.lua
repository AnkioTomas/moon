--[[-- 前光开关快捷动作。
@module koplugin.book.features.panel.actions.desktop.frontlight
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
    --- 长按：KOReader 原生前光对话框（亮度、色温微调）。
    hold = function()
        local Event = require("ui/event")
        require("ui/uimanager"):broadcastEvent(Event:new("ShowFlDialog"))
    end,
}
