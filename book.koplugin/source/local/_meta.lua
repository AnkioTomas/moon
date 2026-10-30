--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

@module source.local._meta
--]]

local _ = require("gettext")

return {
    id = "local",
    name = _("本地书籍"),
    type = "book",
    description = _("设备与 WebDAV 上的电子书"),
    abilities = { _("扫描本地文件夹"), _("WebDAV 同步"), _("导入书籍"), _("进度、笔记与统计") },
}
