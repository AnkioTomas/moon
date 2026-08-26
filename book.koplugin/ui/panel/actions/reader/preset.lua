--[[-- 阅读风格预设快捷动作。
@module koplugin.book.ui.panel.actions.reader.preset
--]]

local Layout = require("ui.reader.layout")
local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "preset",
    title = _("预设"),
    icon = "article",
    scope = "reader",
    keep_open = true,
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        local ui = ctx and ctx.ui
        if not ui then return true end
        return Layout.isReflowable(ui)
    end,
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    active = function(ctx)
        return Layout.matchId(ctx and ctx.ui) ~= "off"
    end,
    ---@param ctx BookQuickPanelContext
    ---@return void
    run = function(ctx)
        Layout.showMenu(ctx.ui)
    end,
}
