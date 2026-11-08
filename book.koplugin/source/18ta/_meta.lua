--[[--
爱看书元信息。

@module source.18ta._meta
--]]

local _ = require("l10n").get("source.18ta")

return {
    id = "18ta",
    name = _("爱看书"),
    type = "chapter",
    description = _("爱看书分类书库与按章在线阅读"),
    abilities = { _("分类书库"), _("完本"), _("在线阅读"), _("整本缓存") },
}
