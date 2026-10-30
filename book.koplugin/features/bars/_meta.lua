--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.bars._meta
--]]

local _ = require("gettext")

return {
    name = _("阅读状态栏"),
    description = _("阅读页上下进度条"),
    abilities = { _("上下状态栏"), _("阅读进度显示") },
}
