--[[-- 书签快捷动作。
@module koplugin.book.ui.panel.actions.bookmark
--]]

local _ = require("gettext")

return {
    id = "bookmark",
    title = _("书签"),
    icon = "bookmark_add",
    active_icon = "bookmark",
    scope = "reader",
    available = function(ctx)
        local ui = ctx and ctx.ui
        return ui and ui.bookmark and ui.bookmark.onToggleBookmark ~= nil
    end,
    active = function(ctx)
        local ui = ctx and ctx.ui
        return ui and ui.bookmark and ui.bookmark.isPageBookmarked
            and ui.bookmark:isPageBookmarked() or false
    end,
    run = function(ctx)
        ctx.ui.bookmark:onToggleBookmark()
    end,
    keep_open = true,
}
