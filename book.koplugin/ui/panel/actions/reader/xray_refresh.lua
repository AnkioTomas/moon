--[[-- 刷新 X-Ray 快捷动作。
@module koplugin.book.ui.panel.actions.reader.xray_refresh
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "xray_refresh",
    title = _("刷新 X-Ray"),
    icon = "sync",
    scope = "reader",
    --- 未显式关闭 X-Ray 时可用。
    ---@return boolean
    available = function()
        return require("utils.settings").get().book_xray_enabled ~= false
    end,
    ---@param ctx BookQuickPanelContext
    ---@return void
    run = function(ctx)
        require("xray.ui").refresh(ctx.ui)
    end,
}
