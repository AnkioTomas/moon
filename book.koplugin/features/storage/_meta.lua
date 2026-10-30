--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.storage._meta
--]]

local _ = require("gettext")

return {
    name = _("存储空间"),
    description = _("占用查看与清理"),
    abilities = { _("空间占用统计"), _("缓存清理") },
}
