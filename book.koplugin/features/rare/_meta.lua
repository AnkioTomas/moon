--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.rare._meta
--]]

local _ = require("gettext")

return {
    name = _("生僻字注音"),
    description = _("拼音、英语音标"),
    abilities = { _("生僻字拼音"), _("英语音标"), _("查词面板附加页") },
}
