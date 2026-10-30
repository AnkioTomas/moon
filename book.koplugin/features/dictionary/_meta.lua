--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.dictionary._meta
--]]

local _ = require("gettext")

return {
    name = _("词典"),
    description = _("多词典查词"),
    abilities = { _("多本词典查词"), _("词典下载") },
}
