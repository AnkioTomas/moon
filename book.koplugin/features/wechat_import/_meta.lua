--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.wechat_import._meta
--]]

local _ = require("gettext")

return {
    name = _("微信书架导入"),
    description = _("书架太大时，借浏览器解码并分批导入"),
    abilities = { _("全量书架分批导入") },
}
