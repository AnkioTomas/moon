--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

@module source.local._meta
--]]

local _ = require("l10n").get("source.local")

return {
    id = "local",
    name = _("本地书籍"),
    type = "book",
    description = _("扫描本地书籍目录，或同步 WebDAV 书库"),
    abilities = { _("本地扫描、书目编辑与元数据补全"), _("WebDAV 书架和书籍文件同步"),
        _("书城下载导入"), _("WebDAV 进度、笔记与统计同步") },
}
