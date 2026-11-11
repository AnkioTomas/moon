--[[-- 自动补目录快捷动作：整书滚动文档可重复生成目录。
@module koplugin.book.features.panel.actions.reader.auto_toc
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "auto_toc",
    title = _("自动补目录"),
    icon = "list_alt_add",
    scope = "reader",
    --- 整书滚动文档且有自定义目录模块时显示；设置页（无 ui）总能勾选。
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        if not (ctx and ctx.ui) then return true end
        local is_chapter = require("reader.session").isChapterMode
        if type(is_chapter) == "function" and is_chapter() then
            return false
        end
        local ui = ctx.ui
        return ui.rolling ~= nil and ui.handmade ~= nil
    end,
    run = function()
        require("reader.session").autoToc()
    end,
}
