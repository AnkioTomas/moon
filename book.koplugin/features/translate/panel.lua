--[[-- 双语对照快捷动作。
@module koplugin.book.features.translate.panel
--]]

require("l10n").apply()
local _ = require("gettext")

local Panel = {}

---@return BookQuickPanelAction[]
function Panel.actions()
    return {{
        id = "bilingual",
        title = _("双语对照"),
        icon = "translate",
        scope = "reader",
        ---@param ctx BookQuickPanelContext|nil
        ---@return boolean
        available = function(ctx)
            local ui = ctx and ctx.ui
            return not ui or require("features.translate.bilingual").available(ui)
        end,
        ---@param ctx BookQuickPanelContext
        ---@return boolean
        active = function(ctx)
            return require("features.translate.bilingual").active(ctx.ui)
        end,
        ---@param ctx BookQuickPanelContext
        run = function(ctx)
            require("features.translate.bilingual").show(ctx.ui)
        end,
    }}
end

return Panel
