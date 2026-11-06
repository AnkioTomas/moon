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
    abilities = { _("搜索与发现"), _("书评"), _("VIP 章节") },
}
