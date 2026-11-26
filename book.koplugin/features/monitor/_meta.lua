--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。
removable = false：不在 list 里，只靠约定文件（setting.lua）登记「我的设备」子页；不开放停用。

@module koplugin.book.features.monitor._meta
--]]

local _ = require("gettext")

return {
    name = _("运行状态"),
    description = _("进程的内存与 CPU 占用"),
    abilities = { _("Lua 内存统计"), _("进程占用查看") },
    removable = false,
}
