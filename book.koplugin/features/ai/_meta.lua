--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.ai._meta
--]]

local _ = require("gettext")

return {
    name = _("AI 阅读助手"),
    description = _("AI 解释、问书、章节摘要"),
    abilities = { _("划词 AI 解释"), _("向书提问"), _("章节摘要") },
}
