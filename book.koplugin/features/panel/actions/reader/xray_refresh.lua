--[[-- 刷新 X-Ray 快捷动作。
@module koplugin.book.features.panel.actions.reader.xray_refresh
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "xray_refresh",
    title = _("刷新 X-Ray"),
    icon = "sync",
    scope = "reader",
    --- X-Ray 开着才可用。
    ---@return boolean
    available = function()
        return require("utils.settings").get("features.xray").book_xray_enabled
    end,
    ---@param ctx BookQuickPanelContext
    run = function(ctx)
        require("features.xray.ui").refresh(ctx.ui)
    end,
}
