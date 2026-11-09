--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.system_ime._meta
--]]

local _ = require("gettext")

return {
    name = _("系统输入法"),
    description = _("Android 上改用系统输入法，不再弹出内置键盘"),
    abilities = { _("系统输入法上屏"), _("键盘高度同步") },
}
