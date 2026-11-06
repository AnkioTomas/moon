--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

豆瓣阅读网页搜索和免费章节不需要登录。书架和已购正文要豆瓣阅读 App 扫码。

@module source.douban._meta
--]]

local _ = require("gettext")

return {
    id = "douban",
    name = _("豆瓣阅读"),
    type = "chapter",
    description = _("豆瓣阅读书架与在线阅读"),
    abilities = { _("搜索与发现"), _("书架同步"), _("进度同步"), _("统计同步"), _("VIP 章节"), _("段评") },
}
