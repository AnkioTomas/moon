--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

@module source.wechat._meta
--]]

local _ = require("gettext")

return {
    id = "wechat",
    name = _("微信读书"),
    type = "chapter",
    description = _("微信读书书架与在线阅读"),
    abilities = { _("搜索与发现"), _("书架同步"), _("进度同步"), _("笔记同步"), _("统计同步"), _("他人段评") },
}
