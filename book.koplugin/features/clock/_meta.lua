--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.clock._meta
--]]

local _ = require("gettext")

return {
    name = _("时间与日期"),
    description = _("时区与网络校时"),
    abilities = { _("时区设置"), _("NTP 网络校时") },
}
