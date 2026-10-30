--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.animation._meta
--]]

local _ = require("gettext")

return {
    name = _("翻页动画"),
    description = _("需要给 KOReader 打补丁"),
    abilities = { _("翻页动画效果"), _("补丁安装与还原"), _("快捷面板开关") },
}
