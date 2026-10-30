--[[--
feature 元信息：功能开关页的名称、说明与能力清单。约定见 features/init.lua。

@module koplugin.book.features.ocr._meta
--]]

local _ = require("gettext")

return {
    name = _("OCR 识字"),
    description = _("图片文字识别"),
    abilities = { _("选区文字识别") },
}
