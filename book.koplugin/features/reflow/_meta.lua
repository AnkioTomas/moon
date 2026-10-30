--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.reflow._meta
--]]

local _ = require("gettext")

return {
    name = _("重新排版"),
    description = _("整本书转成 EPUB 重排"),
    abilities = { _("整本书重新排版"), _("TXT 与其它格式通用") },
}
