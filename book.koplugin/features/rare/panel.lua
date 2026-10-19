--[[--
生僻字注音的阅读快捷面板入口（同翻页动画那样放在阅读面板里）：点开二级菜单，
开关与注音范围（最生僻 / 生僻 / 全部）当场切换，下一次重绘生效，不用退到设置页。

@module koplugin.book.features.rare.panel
--]]

require("l10n").apply()

local _ = require("gettext")

local Panel = {}

local LEVELS = {
    { value = "rarest", text = _("最生僻") },
    { value = "rare", text = _("生僻") },
    { value = "all", text = _("全部") },
}

--- 二级菜单：「开关」+ 三档范围；选范围会顺带打开注音。
local function showMenu()
    local Rare = require("features.rare")
    local s = require("utils.settings").get("features.rare")
    local function apply(fn, ...)
        fn(...)
        require("ui/uimanager"):setDirty("all", "partial")
    end
    local items = {
        { text = _("生僻字注音"), checked = s.rare_enabled and true or false, callback = function() apply(Rare.toggle) end },
    }
    for _idx, level in ipairs(LEVELS) do
        items[#items + 1] = {
            text = level.text,
            checked = s.rare_level == level.value,
            callback = function() apply(Rare.setLevel, level.value) end,
        }
    end
    require("ui.themes.widgets.list"):new{ title = _("生僻字注音"), items = items, centered = true }:show()
end

---@return BookQuickPanelAction[]
function Panel.actions()
    return {
        {
            id = "rare_ruby",
            title = _("生僻字注音"),
            icon = "translate",
            scope = "reader",
            ---@return boolean
            active = function()
                return require("utils.settings").get("features.rare").rare_enabled and true or false
            end,
            run = showMenu,
        },
    }
end

return Panel
