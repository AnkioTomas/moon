 --[[-- 夜间模式快捷动作。
@module koplugin.book.ui.panel.actions.desktop.night
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "night",
    title = _("夜间模式"),
    icon = "dark_mode",
    scope = "desktop",
    event = "ToggleNightMode",
    keep_open = true,
    --- 读取全局夜间模式开关，决定按钮是否处于激活态。
    ---@return boolean
    active = function()
        return G_reader_settings:isTrue("night_mode")
    end,
}
