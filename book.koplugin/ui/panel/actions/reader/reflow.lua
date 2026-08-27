--[[-- 优化排版快捷动作。
@module koplugin.book.ui.panel.actions.reader.reflow
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "reflow",
    title = _("优化排版"),
    icon = "auto_fix_high",
    scope = "reader",
    --- 本地 TXT/MOBI 整书阅读时可排版。
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        local ui = ctx and ctx.ui
        if not ui then
            return true
        end
        local session = require("ui.reader.session").current()
        local identity = session and session.identity
        return require("book.reflow").canReflow(identity)
    end,
    --- 先预览章节目录，确认后再转换替换。
    ---@param ctx BookQuickPanelContext
    ---@return void
    run = function(ctx)
        local session = require("ui.reader.session").current()
        local identity = session and session.identity
        if not identity then
            return
        end
        require("book.reflow").startFromReader(ctx.ui, identity)
    end,
}
