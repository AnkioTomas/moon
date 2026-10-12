--[[--
自动亮度的桌面快捷面板开关。

id 保持 `autolight`：已保存的 quick_panel_actions 与默认列表都按它启用和排序。

@module koplugin.book.features.nightmode.panel
--]]

require("l10n").apply()

local _ = require("gettext")

local Panel = {}

---@return BookQuickPanelAction[]
function Panel.actions()
    return {
        {
            id = "autolight",
            title = _("自动亮度"),
            icon = "brightness_auto",
            scope = "desktop",
            keep_open = true,
            ---@return boolean
            available = function()
                return require("device"):hasFrontlight()
            end,
            ---@return boolean
            active = function()
                return require("utils.settings").get("features.nightmode").auto_light
            end,
            run = function()
                require("features.nightmode").setLight(not require("utils.settings").get("features.nightmode").auto_light)
            end,
        },
    }
end

return Panel
