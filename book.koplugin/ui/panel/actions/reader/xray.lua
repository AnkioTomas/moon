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
    --- 未显式关闭即可用（老配置缺该键时视为开启）。
    ---@return boolean
    available = function()
        return require("utils.settings").get().book_xray_enabled ~= false
    end,
    ---@param ctx BookQuickPanelContext
    ---@return void
    run = function(ctx)
        require("xray.ui").openMain(ctx.ui)
    end,
}
