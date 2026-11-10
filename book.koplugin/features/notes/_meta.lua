--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.notes._meta
--]]

local _ = require("gettext")

return {
    name = _("高亮与笔记"),
    description = _("在浏览器里查看、编辑和导出高亮与笔记"),
    abilities = { _("查看高亮与笔记"), _("编辑备注"), _("删除与导出") },
}
