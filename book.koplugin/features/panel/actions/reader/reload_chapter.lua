--[[-- 重新下载本章快捷动作：只清当前章的缓存并重新拉取。
@module koplugin.book.features.panel.actions.reader.reload_chapter
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "reload_chapter",
    title = _("重新下载本章"),
    icon = "refresh",
    scope = "reader",
    --- 连续章节阅读才有；设置页（无 ui）总能勾选。
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        return not (ctx and ctx.ui) or (require("reader.session").current() or { identity = {} }).identity.chapter_idx ~= nil
    end,
    run = function()
        require("reader.session").reloadChapter()
    end,
}
