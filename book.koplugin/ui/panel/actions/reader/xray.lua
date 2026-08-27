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
    --- 设置页无 ReaderUI 时仍应可配置；运行时由 xray.ui 校验身份与 AI。
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        local ui = ctx and ctx.ui
        if not ui then return true end
        return true
    end,
    ---@param ctx BookQuickPanelContext
    ---@return void
    run = function(ctx)
        require("xray.ui").openMain(ctx.ui)
    end,
}
