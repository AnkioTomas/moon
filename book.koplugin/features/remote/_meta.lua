--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.remote._meta
--]]

local _ = require("gettext")

return {
    name = _("远程管理"),
    description = _("浏览器管理文件与设置"),
    abilities = { _("文件管理"), _("远程输入"), _("共享剪贴板"), _("远程配置"), _("浏览器配对授权") },
}
