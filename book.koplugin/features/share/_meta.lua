--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.share._meta
--]]

local _ = require("gettext")

return {
    name = _("书摘"),
    description = _("把划词或已有高亮生成书摘图片"),
    abilities = {
        _("划词书摘"),
        _("高亮书摘"),
        _("日历 / 经典 / 墨白 / 静影 / 手札 / 锦书"),
        _("纸页摘录"),
        _("画境 / 远山插画"),
    },
}
