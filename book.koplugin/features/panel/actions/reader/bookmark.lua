--[[-- 当前页书签快捷动作。
@module koplugin.book.features.panel.actions.reader.bookmark
--]]

require("l10n").apply()

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "bookmark",
    title = _("书签"),
    icon = "bookmark",
    active_icon = "bookmark_added",
    scope = "reader",
    available = function(ctx)
        local ui = ctx and ctx.ui
        if not ui then return true end
        return ui.bookmark and ui.bookmark.onToggleBookmark ~= nil
    end,
    active = function(ctx)
        local ui = ctx and ctx.ui
        return ui ~= nil and ui.bookmark ~= nil and ui.bookmark:isPageBookmarked()
    end,
    run = function(ctx)
        ctx.ui.bookmark:onToggleBookmark()
    end,
}
