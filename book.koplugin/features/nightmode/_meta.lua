--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.nightmode._meta
--]]

local _ = require("gettext")

return {
    name = _("自动夜间与亮度"),
    description = _("按时间或天气调整"),
    abilities = { _("自动夜间模式"), _("自动亮度") },
}
