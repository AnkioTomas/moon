--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.sidebar._meta
--]]

local _ = require("gettext")

return {
    name = _("阅读侧栏"),
    description = _("阅读页右滑打开"),
    abilities = { _("阅读侧栏"), _("手势触发") },
}
