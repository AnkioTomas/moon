--[[-- 目录快捷动作。
@module koplugin.book.ui.panel.actions.reader.toc
--]]

local _ = require("gettext")

--- 显示 Book 会话目录；未命中时回退到 KOReader 原生目录。
---@param ctx BookQuickPanelContext|nil
---@return void
local function showToc(ctx)
    local ui = ctx and ctx.ui
    local session = require("ui.reader.session")
    local toc = session.toc()
    if not toc then
        if ui and ui.toc and ui.toc.onShowToc then
            ui.toc:onShowToc()
        end
        return
    end
    local current_idx = session.chapterIndex()
    local items = {}
    for _, chapter in ipairs(toc) do
        local idx = tonumber(chapter.idx) or 0
        items[#items + 1] = {
            text = chapter.title or ("#" .. idx),
            value = idx,
            checked = idx == current_idx,
        }
    end
    require("ui.components.popup").list{
        title = _("目录"),
        items = items,
        choice_icons = true,
        --- 选择章节后跳转到 Book 会话对应章。
        ---@param idx number
        ---@return void
        on_select = function(idx) session.gotoChapter(idx) end,
    }
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
    --- 打开目录，并从本地 Book 会话目录数据构建选项。
    run = showToc,
}
