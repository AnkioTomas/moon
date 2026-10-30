--[[--
行间标注快捷面板：注音、WordWise 释义各一个开关（可同时开）；长按打开档位菜单。

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

--- 长按：标注范围二级菜单。
---@param ctx table|nil
local function showLevels(ctx)
    local Rare = require("features.rare")
    local s = Rare.migrate()
    local ui = ctx and ctx.ui
    local function apply(fn, ...)
        fn(...)
        require("ui/uimanager"):setDirty("all", "partial")
    end
    local items = {}
    for _idx, level in ipairs(LEVELS) do
        items[#items + 1] = {
            text = level.text,
            checked = s.rare_level == level.value,
            callback = function() apply(Rare.setLevel, level.value, ui) end,
        }
    end
    require("ui.themes.widgets.list"):new{ title = _("标注范围"), items = items, centered = true }:show()
end

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
                return require("features.rare").kindOn("ruby")
            end,
            ---@param ctx table|nil
            run = function(ctx)
                require("features.rare").toggleKind("ruby", ctx and ctx.ui)
            end,
            hold = showLevels,
        },
        {
            id = "rare_wordwise",
            title = _("WordWise 释义"),
            icon = "menu_book",
            scope = "reader",
            keep_open = true,
            ---@return boolean
            active = function()
                return require("features.rare").kindOn("wordwise")
            end,
            ---@param ctx table|nil
            run = function(ctx)
                require("features.rare").toggleKind("wordwise", ctx and ctx.ui)
            end,
            hold = showLevels,
        },
    }
end

return Panel
