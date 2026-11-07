--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

@module source.qqreader._meta
--]]

local _ = require("gettext")

return {
    id = "qqreader",
    name = _("QQ阅读"),
    type = "chapter",
    description = _("QQ阅读书架与在线阅读"),
    abilities = { _("扫码登录"), _("搜索与发现"), _("书架同步"), _("VIP 章节"), _("书评"), _("进度同步") },
}
