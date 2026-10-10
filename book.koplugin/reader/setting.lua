--[[--
阅读器的配置声明（settings/reader.lua，经 `utils.settings.get("reader")` 读写）。

@module koplugin.book.reader.setting
--]]

return {
    defaults = {
        auto_mark_read_at_99 = false,
        selection_handles_enabled = true,
        -- 划词菜单的显示顺序；关闭状态仍由 reader_popup_buttons 单独保存。
        reader_popup_button_order = {
            "select", "highlight", "copy", "add_note", "dictionary", "translate",
            "wikipedia", "xray", "ai_explain", "search", "view_html", "qrcode",
        },
        reader_popup_buttons = {
            select = true,
            highlight = true,
            copy = true,
            add_note = true,
            wikipedia = true,
            dictionary = true,
            translate = true,
            xray = true,
            ai_explain = true,
            view_html = true,
            qrcode = true,
            search = true,
        },
    },
}
