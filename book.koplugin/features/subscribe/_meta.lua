--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.subscribe._meta
--]]

local _ = require("gettext")

return {
    name = _("订阅"),
    description = _("RSS 与网页订阅"),
    abilities = { _("RSS 订阅"), _("网页订阅"), _("桌面订阅页签") },
}
