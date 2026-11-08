--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

网易云阅读网页搜索、分类书库和免费章节不需要登录。
电脑端支持手机号密码、微信扫码以及电脑浏览器 Cookie 登录。
登录后同步官网书架，本地增删联网后上行。

@module source.netease._meta
--]]

local _ = require("l10n").get("source.netease")

return {
    id = "netease",
    name = _("网易云阅读"),
    type = "chapter",
    description = _("网易云阅读在线阅读"),
    abilities = { _("搜索与发现"), _("书架同步"), _("进度同步"), _("书评"), _("VIP 章节") },
}
