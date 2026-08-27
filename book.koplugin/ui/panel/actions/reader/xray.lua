--[[-- X-Ray 快捷动作。
@module koplugin.book.ui.panel.actions.reader.xray
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "xray",
    title = _("X-Ray"),
    icon = "person_search",
    scope = "reader",
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        if require("utils.settings").get().book_xray_enabled == false then
            return false
        end
        return true
    end,
    ---@param ctx BookQuickPanelContext
    ---@return void
    run = function(ctx)
        require("xray.ui").openMain(ctx.ui)
    end,
}
