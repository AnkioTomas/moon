--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.ime._meta
--]]

local _ = require("gettext")

return {
    name = _("中文输入法"),
    description = _("拼音、五笔、仓颉、速成、注音；无月读词库时用 KO 码表画同一候选条"),
    abilities = { _("候选词栏"), _("简繁转换"), _("词库下载（可选）"), _("虚拟键盘收起键") },
}
