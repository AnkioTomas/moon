--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.ime._meta
--]]

local _ = require("gettext")

return {
    name = _("中文输入法"),
    description = _("拼音、五笔、仓颉、速成、注音"),
    abilities = { _("候选词栏"), _("简繁转换"), _("词库下载"), _("虚拟键盘收起键") },
}
