--[[-- 目录快捷动作。
@module koplugin.book.ui.panel.actions.reader.toc
--]]

local _ = require("gettext")

--- 显示目录：整书复用 KOReader 原生树形目录，连续章节使用 Book 会话目录。
---@param ctx BookQuickPanelContext|nil
local function showToc(ctx)
    local ui = ctx and ctx.ui
    local toc_widget = ui and ui.toc
    local session = require("ui.reader.session")
    if toc_widget then
        if not session.isChapterMode() and toc_widget.onShowToc then
            toc_widget:onShowToc()
            return
        end
    end

    local toc = session.toc()
    if not toc then
        if toc_widget then
            if toc_widget.onShowToc then
                toc_widget:onShowToc()
            end
        end
        return
    end
    require("ui.reader.chapter_toc").show(toc, session.chapterIndex(), function(idx)
        session.gotoChapter(idx)
    end)
end

---@type BookQuickPanelAction
return {
    id = "toc",
    title = _("目录"),
    icon = "menu_book",
    scope = "reader",
    --- Book 会话目录或 KOReader 原生目录存在时显示。
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        local ui = ctx and ctx.ui
        if not ui then return true end
        return require("ui.reader.session").toc() ~= nil
            or (ui.toc and ui.toc.onShowToc ~= nil)
    end,
    --- 整书打开 KOReader 原生目录；连续章节从 Book 会话目录构建选项。
    run = showToc,
}
