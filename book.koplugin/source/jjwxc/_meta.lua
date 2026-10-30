--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

@module source.jjwxc._meta
--]]

local _ = require("gettext")

return {
    id = "jjwxc",
    name = _("晋江文学城"),
    type = "chapter",
    description = _("晋江文学城书架与在线阅读"),
    abilities = { _("搜索与发现"), _("书架同步"), _("VIP 章节"), _("他人段评") },
}
