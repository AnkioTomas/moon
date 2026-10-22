--[[-- 简繁转换快捷动作。
@module koplugin.book.features.ime.panel
--]]

require("l10n").apply()
local _ = require("gettext")

local Panel = {}

---@return BookQuickPanelAction[]
function Panel.actions()
    return {{
        id = "hanzi",
        title = _("简繁转换"),
        icon = "translate",
        scope = "reader",
        ---@param ctx BookQuickPanelContext|nil
        ---@return boolean
        available = function(ctx)
            local ui = ctx and ctx.ui
            return not ui or require("features.ime.convert").availableAny(ui)
        end,
        ---@param ctx BookQuickPanelContext
        ---@return boolean
        active = function(ctx)
            return require("features.ime.convert").activeAny(ctx.ui)
        end,
        ---@param ctx BookQuickPanelContext
        run = function(ctx)
            require("features.ime.convert").show(ctx.ui)
        end,
    }}
end

return Panel
