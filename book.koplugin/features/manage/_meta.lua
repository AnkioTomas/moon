--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。
removable = false：功能开关自己不能被停用。

@module koplugin.book.features.manage._meta
--]]

local _ = require("gettext")

return {
    name = _("功能开关"),
    description = _("停用用不到的功能，减少内存占用"),
    abilities = { _("停用与再启用功能") },
    removable = false,
}
