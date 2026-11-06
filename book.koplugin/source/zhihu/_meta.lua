--[[--
书源元信息。

知乎盐选没有云端书架。榜单匿名可读。正文折叠时是未购买。

@module source.zhihu._meta
--]]

local _ = require("gettext")

return {
    id = "zhihu",
    name = _("知乎盐选"),
    type = "chapter",
    description = _("知乎盐选在线阅读"),
    abilities = { _("搜索与发现"), _("VIP 章节") },
}
