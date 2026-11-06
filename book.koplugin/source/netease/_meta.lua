--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

网易云阅读网页搜索、榜单和免费章节不需要登录。
登录页是短信、密码、邮箱和微博，没有扫码。阅读位置在登录后上报。
书架列表还没在登录态下见过，所以先不同步书架。

@module source.netease._meta
--]]

local _ = require("gettext")

return {
    id = "netease",
    name = _("网易云阅读"),
    type = "chapter",
    description = _("网易云阅读在线阅读"),
    abilities = { _("搜索与发现"), _("进度同步"), _("书评"), _("VIP 章节") },
}
