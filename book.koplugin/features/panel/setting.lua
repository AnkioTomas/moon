--[[--
快捷面板配置键（settings/panel.lua）与设置：桌面 / 阅读两个面板编辑页，挂在根页对应分组。
编辑行与预览在 features.panel.settings。

@module koplugin.book.features.panel.setting
--]]

local _ = require("gettext")

local Setting = {}

-- 新安装默认启用的动作，顺序即面板顺序。feature 新开关不在这份列表里就保持关闭；已有配置仍保持用户选择。
Setting.defaults = {
    quick_panel_actions = {
        "night", "wifi", "remote", "rotate", "refresh", "screenshot", "frontlight", "autolight", "suspend",
    },
    quick_panel_reader_actions = { "toc", "font", "reflow", "highlights", "bookorbit", "xray", "page_turn" },
}

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local QuickPanel = require("features.panel.settings")
    local T = require("ffi/util").template
    return {
        {
            id = "desktop", group = "desktop", order = 60,
            icon = "dashboard_customize", title = _("桌面快捷面板"), subtitle = _("面板开关与顺序"),
            status = T(_("已启用 %1 项"), QuickPanel.enabledCount("desktop")), status_on = true,
            page = {
                title = _("桌面快捷面板"),
                preview = function(width) return QuickPanel.preview("desktop", width) end,
                sections = function() return {{ title = _("桌面"), rows = QuickPanel.rows("desktop", desktop) }} end,
            },
        },
        {
            id = "reader", group = "reader", order = 60,
            icon = "dashboard_customize", title = _("阅读快捷面板"), subtitle = _("面板按钮与顺序"),
            status = T(_("已启用 %1 项"), QuickPanel.enabledCount("reader")), status_on = true,
            page = {
                title = _("阅读快捷面板"),
                preview = function(width) return QuickPanel.preview("reader", width) end,
                sections = function() return {{ title = _("阅读"), rows = QuickPanel.rows("reader", desktop) }} end,
            },
        },
    }
end

return Setting
