--[[--
feature 元信息：系统输入法（Android dex 后端）。

设置入口已并入 features.ime；本目录只保留后端与配置声明。

@module koplugin.book.features.system_ime._meta
--]]

local _ = require("gettext")

return {
    name = _("系统输入法"),
    description = _("Android 键盘（微信输入法等）"),
    abilities = { _("系统键盘"), _("候选与联想") },
}
