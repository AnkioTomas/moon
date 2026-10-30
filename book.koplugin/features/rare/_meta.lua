--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.rare._meta
--]]

local _ = require("gettext")

return {
    name = _("行间标注"),
    description = _("拼音、英语音标、WordWise 短释义"),
    abilities = { _("生僻字拼音"), _("英语音标"), _("WordWise 释义"), _("查词面板附加页") },
}
