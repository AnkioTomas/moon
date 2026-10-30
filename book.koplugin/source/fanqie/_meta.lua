--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

@module source.fanqie._meta
--]]

local _ = require("gettext")

return {
    id = "fanqie",
    name = _("番茄小说"),
    type = "chapter",
    description = _("番茄小说书架与在线阅读"),
    abilities = { _("搜索与发现"), _("书架同步"), _("进度同步"), _("他人段评") },
}
