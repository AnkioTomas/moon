--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

@module source.kavita._meta
--]]

local _ = require("gettext")

return {
    id = "kavita",
    name = _("Kavita"),
    type = "book",
    description = _("同步 Kavita 书架、电子书与漫画"),
    abilities = { _("书架与卷目录同步（只读）"), _("进度同步"), _("EPUB 划线同步"), _("阅读历史拉取"),
        _("漫画在线阅读与缓存（需 kamare 增强版）") },
}
