--[[-- 旋转屏幕快捷动作。
@module koplugin.book.ui.panel.actions.desktop.rotate
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "rotate",
    title = _("旋转屏幕"),
    icon = "screen_rotation_alt",
    scope = "desktop",
    event = "IterateRotation",
}
