--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.cookie._meta
--]]

local _ = require("gettext")

return {
    name = _("Cookie 存储"),
    description = _("接收浏览器扩展同步的 Cookie"),
    abilities = { _("接收浏览器 Cookie"), _("书源免扫码登录") },
}
