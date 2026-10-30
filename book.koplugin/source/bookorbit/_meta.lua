--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

@module source.bookorbit._meta
--]]

local _ = require("gettext")

return {
    id = "bookorbit",
    name = _("BookOrbit"),
    type = "book",
    description = _("连接 BookOrbit 服务器"),
    abilities = { _("书架同步"), _("进度同步"), _("笔记同步") },
}
