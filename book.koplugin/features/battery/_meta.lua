--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。
removable = false：只靠约定文件生效，不在 list 里，没有可停用的加载动作。

@module koplugin.book.features.battery._meta
--]]

local _ = require("gettext")

return {
    name = _("电池"),
    description = _("健康度、循环次数与充放电"),
    abilities = { _("电池健康度") },
    removable = false,
}
