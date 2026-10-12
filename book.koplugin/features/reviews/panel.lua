--[[--
段评的阅读快捷面板开关：给本地书关联微信读书书目，借它的段评。

@module koplugin.book.features.reviews.panel
--]]

require("l10n").apply()

local _ = require("gettext")

local Panel = {}

---@return BookQuickPanelAction[]
function Panel.actions()
    return {{
        id = "wechat_reviews_link",
        title = _("关联微信段评"),
        icon = "forum",
        scope = "reader",
        ---@param ctx BookQuickPanelContext|nil
        ---@return boolean
        available = function(ctx)
            local ui = ctx and ctx.ui
            return not ui or require("features.reviews.link").available(ui)
        end,
        ---@param ctx BookQuickPanelContext
        run = function(ctx)
            require("features.reviews.link").open(ctx.ui)
        end,
    }}
end

return Panel
