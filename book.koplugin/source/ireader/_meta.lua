--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

掌阅 PC（pc.ireader.com）扫码登录后同步 App 书架；书城搜索与频道来自手机站 m.zhangyue.com。

@module source.ireader._meta
--]]

local _ = require("gettext")

return {
    id = "ireader",
    name = _("掌阅书城"),
    type = "chapter",
    description = _("掌阅书架与在线阅读"),
    abilities = { _("搜索与发现"), _("书架同步"), _("进度同步"), _("VIP 章节"), _("书评"), _("扫码登录"), _("浏览器登录") },
}
