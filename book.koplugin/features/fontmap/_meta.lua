--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.fontmap._meta
--]]

local _ = require("gettext")

return {
    name = _("书内字体映射"),
    description = _("将书中指定的字体替换为本机字体"),
    abilities = { _("书内字体替换") },
}
