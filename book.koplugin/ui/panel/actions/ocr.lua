--[[-- OCR 快捷动作。
@module koplugin.book.ui.panel.actions.ocr
--]]

local _ = require("gettext")

return {
    id = "ocr",
    title = _("OCR"),
    icon = "document_scanner",
    scope = "reader",
    available = function(ctx)
        return ctx and ctx.ui ~= nil
    end,
    run = function(ctx)
        require("ui.reader.ocr").open(ctx.ui)
    end,
}
