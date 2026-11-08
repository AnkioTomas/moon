--[[--
书源元信息。

@module source.kuaikan._meta
--]]

local _ = require("gettext")

return {
    id = "kuaikan",
    name = _("快看漫画"),
    type = "chapter",
    description = _("快看漫画在线阅读"),
    abilities = { _("微信扫码登录"), _("密码登录"), _("短信登录"), _("书架同步"), _("阅读进度同步"), _("搜索与发现"), _("话题页评论（首话）"), _("章节评论"), _("缓存章节") },
}
