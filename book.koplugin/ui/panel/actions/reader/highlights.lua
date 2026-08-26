--[[-- 高亮与笔记快捷动作。
@module koplugin.book.ui.panel.actions.reader.highlights
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "highlights",
    title = _("高亮与笔记"),
    icon = "format_ink_highlighter",
    scope = "reader",
    --- 当前文档有书签/高亮面板入口时显示。
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        local ui = ctx and ctx.ui
        if not ui then return true end
        return ui.bookmark and ui.bookmark.onShowBookmark ~= nil
    end,
    --- 打开高亮、书签和笔记列表。
    ---@param ctx BookQuickPanelContext
    ---@return void
    run = function(ctx)
        ctx.ui.bookmark:onShowBookmark()
    end,
}
