--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

@module source.legado._meta
--]]

local _ = require("gettext")

return {
    id = "legado",
    name = _("开源阅读"),
    type = "chapter",
    description = _("连接阅读 App、reader3 或轻阅读服务"),
    abilities = { _("书架与章节正文"), _("目录及整本缓存"), _("进度同步"), _("从服务端书架删除") },
}
