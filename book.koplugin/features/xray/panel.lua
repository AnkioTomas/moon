--[[--
X-Ray 的阅读快捷面板开关：打开 X-Ray、页内标记开关、刷新 X-Ray。

id 保持 `xray` / `xray_refresh`：已保存的 quick_panel_reader_actions 与默认列表都按它启用和排序。

@module koplugin.book.features.xray.panel
--]]

require("l10n").apply()

local _ = require("gettext")

local Panel = {}

local function enabled()
    return require("features.xray").available()
end

---@return BookQuickPanelAction[]
function Panel.actions()
    return {
        {
            id = "xray",
            title = _("X-Ray"),
            icon = "person_search",
            scope = "reader",
            available = enabled,
            ---@param ctx BookQuickPanelContext
            run = function(ctx)
                require("features.xray.ui").openMain(ctx.ui)
            end,
        },
        {
            id = "xray_marks",
            title = _("X-Ray 标记"),
            icon = "format_underlined",
            scope = "reader",
            available = enabled,
            keep_open = true,
            active = function()
                return require("features.xray.marks").enabled()
            end,
            ---@param ctx BookQuickPanelContext
            run = function(ctx)
                local Marks = require("features.xray.marks")
                Marks.setEnabled(not Marks.enabled(), ctx.ui)
            end,
        },
        {
            id = "xray_refresh",
            title = _("刷新 X-Ray"),
            icon = "sync",
            scope = "reader",
            available = enabled,
            ---@param ctx BookQuickPanelContext
            run = function(ctx)
                require("features.xray.ui").refresh(ctx.ui)
            end,
        },
    }
end

return Panel
