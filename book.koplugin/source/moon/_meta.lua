--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

@module source.moon._meta
--]]

local _ = require("gettext")

return {
    id = "moon",
    name = _("月读服务"),
    type = "book",
    description = _("从月读服务端同步书架与阅读数据"),
    abilities = { _("下载整本书"), _("书架同步（不支持加入）"), _("进度、笔记与统计双向同步") },
}
