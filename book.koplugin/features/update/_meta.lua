--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。
removable = false：不开放停用，保证用户始终能自更新。

@module koplugin.book.features.update._meta
--]]

local _ = require("gettext")

return {
    name = _("插件更新"),
    description = _("检查并安装月读更新"),
    abilities = { _("自动检查更新"), _("手动检查更新"), _("词库更新") },
    removable = false,
}
