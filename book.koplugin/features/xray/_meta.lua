--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.xray._meta
--]]

local _ = require("gettext")

return {
    name = _("X-Ray"),
    description = _("人物与地点标注"),
    abilities = { _("人物与地点标注"), _("AI 分析全书") },
}
