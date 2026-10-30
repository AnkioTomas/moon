--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.translate._meta
--]]

local _ = require("gettext")

return {
    name = _("翻译"),
    description = _("划词翻译与双语对照"),
    abilities = { _("划词翻译"), _("整书双语对照"), _("Edge 与 AI 翻译") },
}
