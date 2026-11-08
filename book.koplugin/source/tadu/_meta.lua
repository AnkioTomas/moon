--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

塔读（www.tadu.com）用微信扫码登录。书架、搜索、目录、正文都是网页接口。

@module source.tadu._meta
--]]

local _ = require("l10n").get("source.tadu")

return {
    id = "tadu",
    name = _("塔读小说"),
    type = "chapter",
    description = _("塔读书架与在线阅读"),
    abilities = { _("搜索与发现"), _("书架同步"), _("书评"), _("离线缓存") },
}
