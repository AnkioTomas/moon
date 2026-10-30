--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.extensions._meta
--]]

local _ = require("gettext")

return {
    name = _("拓展页签"),
    description = _("桌面底栏的其它插件入口"),
    abilities = { _("底栏拓展页签"), _("弹出其它插件的主菜单入口") },
}
