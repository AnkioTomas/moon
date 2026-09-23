--[[-- BookOrbit 当前书籍同步快捷动作。
@module koplugin.book.ui.panel.actions.reader.bookorbit
--]]

local _ = require("gettext")

---@param ui table|nil
---@return boolean
local function available(ui)
    if ui == nil then return true end
    return ui.bookorbit ~= nil and type(ui.bookorbit.onBookOrbitSyncBook) == "function"
end

---@type BookQuickPanelAction
return {
    id = "bookorbit",
    title = _("同步到 BookOrbit"),
    icon = "sync",
    scope = "reader",
    available = function(ctx)
        return available(ctx and ctx.ui)
    end,
    run = function(ctx)
        local Event = require("ui/event")
        ctx.ui:handleEvent(Event:new("BookOrbitSyncBook"))
    end,
}
