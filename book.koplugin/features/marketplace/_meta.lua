--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.marketplace._meta
--]]

local _ = require("gettext")

return {
    name = _("插件市场"),
    description = _("从月读插件市场浏览并安装月读与 KOReader 插件"),
    abilities = {
        _("按分类与生态筛选插件"),
        _("查看插件简介与 README"),
        _("下载并安装第三方插件"),
    },
}
