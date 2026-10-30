--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.azw3._meta
--]]

local _ = require("gettext")

return {
    name = _("AZW3 支持"),
    description = _("打开 AZW3 / KF8 书籍"),
    abilities = { _("注册 AZW3 文档提供者"), _("KF8 重建") },
}
