--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.panel._meta
--]]

local _ = require("gettext")

return {
    name = _("快捷面板"),
    description = _("桌面与阅读页的快捷开关"),
    abilities = { _("桌面快捷面板"), _("阅读页快捷面板"), _("前光调节") },
}
