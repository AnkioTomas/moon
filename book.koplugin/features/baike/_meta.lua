--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.baike._meta
--]]

local _ = require("gettext")

return {
    name = _("百科"),
    description = _("划词查百科"),
    abilities = { _("划词查百科"), _("查词面板百科页") },
}
