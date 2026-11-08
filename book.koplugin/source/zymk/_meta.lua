--[[--
书源元信息。

@module source.zymk._meta
--]]

local _ = require("l10n").get("source.zymk")

return {
    id = "zymk",
    name = _("知音漫客"),
    type = "chapter",
    description = _("知音漫客在线阅读"),
    abilities = { _("短信验证码登录"), _("密码登录"), _("Cookie 登录"), _("书架同步"),
        _("搜索与发现"), _("章节缓存"), _("书评") },
}
