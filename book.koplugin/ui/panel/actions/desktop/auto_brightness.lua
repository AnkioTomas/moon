--[[-- 自动亮度快捷动作。
@module koplugin.book.ui.panel.actions.desktop.auto_brightness
--]]

local AutoBrightness = require("ui.auto_brightness")
local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "auto_brightness",
    title = _("自动亮度"),
    icon = "brightness_auto",
    scope = "desktop",
    keep_open = true,
    available = function()
        return AutoBrightness:isSupported()
    end,
    active = function()
        return AutoBrightness:isEnabled()
    end,
    run = function()
        AutoBrightness:toggle()
    end,
}
