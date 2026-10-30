--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.passcode._meta
--]]

local _ = require("gettext")

return {
    name = _("锁屏密码"),
    description = _("唤醒后需要输入 PIN"),
    abilities = { _("启动与唤醒时锁定"), _("PIN 数字键盘") },
}
