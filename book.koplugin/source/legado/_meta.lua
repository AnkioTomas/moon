--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

@module source.legado._meta
--]]

local _ = require("gettext")

return {
    id = "legado",
    name = _("开源阅读"),
    type = "chapter",
    description = _("连接开源阅读（Legado）服务"),
    abilities = { _("书架同步"), _("进度同步"), _("删除书籍") },
}
