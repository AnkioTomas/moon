--[[-- 刷新目录快捷动作：连续章节会话强制重拉源目录。
@module koplugin.book.features.panel.actions.reader.refresh_toc
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "refresh_toc",
    title = _("刷新目录"),
    icon = "autorenew",
    scope = "reader",
    --- 连续章节阅读才有；设置页（无 ui）总能勾选。
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        return not (ctx and ctx.ui) or require("reader.session").isChapterMode()
    end,
    run = function()
        require("reader.session").refreshToc()
    end,
}
