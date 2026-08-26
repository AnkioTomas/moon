--[[-- 全屏刷新快捷动作。
@module koplugin.book.ui.panel.actions.desktop.refresh
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "refresh",
    title = _("全屏刷新"),
    icon = "autorenew",
    scope = "desktop",
    event = "FullRefresh",
}
