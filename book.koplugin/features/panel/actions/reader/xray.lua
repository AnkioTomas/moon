--[[-- X-Ray 快捷动作。
@module koplugin.book.features.panel.actions.reader.xray
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "xray",
    title = _("X-Ray"),
    icon = "person_search",
    scope = "reader",
    --- X-Ray 开着才可用。
    ---@return boolean
    available = function()
        return require("utils.settings").get("features.xray").book_xray_enabled
    end,
    ---@param ctx BookQuickPanelContext
    run = function(ctx)
        require("features.xray.ui").openMain(ctx.ui)
    end,
}
