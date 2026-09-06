--[[-- 目录快捷动作。
@module koplugin.book.ui.panel.actions.reader.toc
--]]

local _ = require("gettext")

--- 显示目录：整书复用 KOReader 原生树形目录，连续章节使用 Book 会话目录。
---@param ctx BookQuickPanelContext|nil
---@return void
local function showToc(ctx)
    local ui = ctx and ctx.ui
    local session = require("ui.reader.session")
    local native_toc = ui and ui.toc and ui.toc.onShowToc
    if not session.isChapterMode() and native_toc then
        ui.toc:onShowToc()
        return
    end

    local toc = session.toc()
    if not toc then
        if native_toc then
            ui.toc:onShowToc()
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
