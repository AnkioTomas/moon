--[[-- 打开 KOReader 原生顶部面板。
@module koplugin.book.ui.panel.actions.native_menu
--]]

local _ = require("gettext")

return {
    id = "native_menu",
    title = _("原生顶部面板"),
    icon = "more_horiz",
    scope = "desktop",
    event = "ShowMenu",
}
