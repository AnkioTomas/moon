--[[-- 字典快捷动作。
@module koplugin.book.ui.panel.actions.reader.dictionary
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "dictionary",
    title = _("字典"),
    icon = "translate",
    scope = "reader",
    --- 当前阅读器挂载字典模块时显示。
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        local ui = ctx and ctx.ui
        if not ui then return true end
        return ui.dictionary ~= nil
    end,
    --- 打开 KOReader 字典入口。
    ---@param ctx BookQuickPanelContext
    ---@return void
    run = function(ctx)
        require("ui.reader.dictionary").open(ctx.ui)
    end,
}
