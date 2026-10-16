--[[--
生僻字注音的阅读快捷面板开关（同翻页动画那样放在阅读面板里）：一点开 / 关，下一次重绘生效。

@module koplugin.book.features.rare.panel
--]]

require("l10n").apply()

local _ = require("gettext")

local Panel = {}

---@return BookQuickPanelAction[]
function Panel.actions()
    return {
        {
            id = "rare_ruby",
            title = _("生僻字注音"),
            icon = "translate",
            scope = "reader",
            keep_open = true,
            ---@return boolean
            active = function()
                return require("utils.settings").get("features.rare").rare_enabled and true or false
            end,
            run = function()
                require("features.rare").toggle()
            end,
        },
    }
end

return Panel
