--[[--
书源元信息：id / 名称 / 类型，加上启用页展示用的说明与能力清单。`init.lua` 的 `meta()` 直接返回本表。

@module source.kindle._meta
--]]

local _ = require("gettext")

return {
    id = "kindle",
    name = _("Kindle 书库"),
    type = "book",
    description = _("读取 Kindle 设备自带的书库"),
    abilities = { _("书架同步") },
}
