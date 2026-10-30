--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.bluetooth._meta
--]]

local _ = require("gettext")

return {
    name = _("蓝牙"),
    description = _("联动蓝牙守护进程"),
    abilities = { _("蓝牙开关与设备窗口"), _("顶栏蓝牙状态"), _("翻页器连接") },
}
