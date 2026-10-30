--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

@module source.qimao._meta
--]]

local _ = require("gettext")

return {
    id = "qimao",
    name = _("七猫小说"),
    type = "chapter",
    description = _("七猫小说书架与在线阅读"),
    abilities = { _("搜索与发现"), _("书架同步"), _("进度同步") },
}
