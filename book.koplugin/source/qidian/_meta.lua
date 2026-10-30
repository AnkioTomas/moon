--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

@module source.qidian._meta
--]]

local _ = require("gettext")

return {
    id = "qidian",
    name = _("起点中文网"),
    type = "chapter",
    description = _("起点中文网书架与在线阅读"),
    abilities = { _("搜索与发现"), _("书架同步"), _("进度同步"), _("VIP 章节"), _("他人段评") },
}
