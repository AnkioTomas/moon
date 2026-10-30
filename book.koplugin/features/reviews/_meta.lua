--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.reviews._meta
--]]

local _ = require("gettext")

return {
    name = _("他人段评"),
    description = _("页内显示微信读书段评"),
    abilities = { _("页内段评标记") },
}
