--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

书旗网页（t.shuqi.com）搜索和免费章节不需要登录。书架可用验证码或官网 Cookie 登录，滑块在远程管理页完成。

@module source.shuqi._meta
--]]

local _ = require("gettext")

return {
    id = "shuqi",
    name = _("书旗"),
    type = "chapter",
    description = _("书旗书架与在线阅读"),
    abilities = { _("搜索与发现"), _("书架同步"), _("进度同步"), _("书评"), _("VIP 章节") },
}
