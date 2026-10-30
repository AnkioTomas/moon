--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.wallpaper._meta
--]]

local _ = require("gettext")

return {
    name = _("壁纸"),
    description = _("每日壁纸"),
    abilities = { _("每日壁纸") },
}
