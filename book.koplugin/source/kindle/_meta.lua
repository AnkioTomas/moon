--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

@module source.kindle._meta
--]]

local _ = require("gettext")

return {
    id = "kindle",
    name = _("Kindle 书库"),
    type = "book",
    description = _("读取 Kindle 系统书库，开书依赖 kindle.koplugin"),
    abilities = { _("读取 Kindle 系统书架"), _("DRM／KFX 书籍交由 kindle.koplugin 打开") },
}
