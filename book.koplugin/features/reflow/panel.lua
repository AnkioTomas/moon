--[[-- 优化排版快捷动作。
@module koplugin.book.features.reflow.panel
--]]

require("l10n").apply()
local _ = require("gettext")

local Panel = {}

---@return BookQuickPanelAction[]
function Panel.actions()
    return {{
        id = "reflow",
        title = _("优化排版"),
        icon = "auto_fix_high",
        scope = "reader",
        ---@param ctx BookQuickPanelContext|nil
        ---@return boolean
        available = function(ctx)
            local ui = ctx and ctx.ui
            return not ui or require("features.reflow").available(ui)
        end,
        ---@param ctx BookQuickPanelContext
        ---@return boolean
        active = function(ctx)
            return require("features.reflow").active(ctx.ui)
        end,
        ---@param ctx BookQuickPanelContext
        run = function(ctx)
            require("features.reflow").show(ctx.ui)
        end,
    }}
end

return Panel
