--[[-- 阅读设置快捷动作：打开设置里的「阅读」分组（行为 / 栏 / 侧栏 / 划词等）。
@module koplugin.book.features.panel.actions.reader.settings
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "settings",
    title = _("阅读设置"),
    icon = "settings",
    scope = "reader",
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        return not (ctx and ctx.ui) or ctx.ui.document ~= nil
    end,
    ---@param ctx BookQuickPanelContext
    run = function(ctx)
        local plugin = ctx.ui and ctx.ui.book
        require("desktop.pages.setting").openReader(plugin)
    end,
}
