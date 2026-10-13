--[[--
AI 阅读助手的阅读快捷面板开关：回顾前文、读书报告、问书。未配置 AI 时不出现。

@module koplugin.book.features.ai.panel
--]]

require("l10n").apply()

local _ = require("gettext")

local Panel = {}

---@return boolean
local function configured()
    return require("ai").isConfigured()
end

---@return BookQuickPanelAction[]
function Panel.actions()
    return {
        {
            id = "ai_recap",
            title = _("回顾前文"),
            icon = "history",
            scope = "reader",
            available = configured,
            run = function()
                require("features.ai.recap").show()
            end,
        },
        {
            id = "ai_report",
            title = _("读书报告"),
            icon = "description",
            scope = "reader",
            available = configured,
            ---@param ctx BookQuickPanelContext
            run = function(ctx)
                require("features.ai.report").open(ctx.ui)
            end,
        },
        {
            id = "ai_ask",
            title = _("问书"),
            icon = "contact_support",
            scope = "reader",
            available = configured,
            ---@param ctx BookQuickPanelContext
            run = function(ctx)
                require("features.ai.explain").askBook(ctx.ui)
            end,
        },
    }
end

return Panel
