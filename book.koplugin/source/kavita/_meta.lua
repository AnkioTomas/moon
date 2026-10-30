--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

@module source.kavita._meta
--]]

local _ = require("gettext")

return {
    id = "kavita",
    name = _("Kavita"),
    type = "book",
    description = _("连接 Kavita 服务器的漫画与电子书"),
    abilities = { _("书架同步"), _("进度同步"), _("笔记同步"), _("统计同步"), _("漫画缓存（需 kamare 增强版）") },
}
