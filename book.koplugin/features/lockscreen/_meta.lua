--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.lockscreen._meta
--]]

local _ = require("gettext")

return {
    name = _("锁屏显示"),
    description = _("组合壁纸与锁屏主体"),
    abilities = { _("组合壁纸"), _("锁屏主体（当前阅读、统计、留言）"), _("每日背景") },
}
