--[[-- 目录快捷动作。
@module koplugin.book.features.panel.actions.reader.toc
--]]

local _ = require("gettext")

--- 显示目录：整书复用 KOReader 原生树形目录，连续章节使用 Book 会话目录。
---@param ctx BookQuickPanelContext|nil
local function showToc(ctx)
    local toc_widget = ctx and ctx.ui and ctx.ui.toc
    local session = require("reader.session")
    if toc_widget and not session.isChapterMode() then
        toc_widget:onShowToc()
        return
    end
    local toc = session.toc()
    if toc then
        require("reader.chapter_toc").show(toc, session.chapterIndex(), function(idx, anchor)
            session.gotoChapter(idx, anchor and anchor.id and { xpointer = "#" .. anchor.id })
        end)
    elseif toc_widget then
        toc_widget:onShowToc()
    end
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
        return require("reader.session").toc() ~= nil
            or (ui.toc and ui.toc.onShowToc ~= nil)
    end,
    --- 整书打开 KOReader 原生目录；连续章节从 Book 会话目录构建选项。
    run = showToc,
}
