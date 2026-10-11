--[[--
翻页动画风格快捷动作。

id 保持 `page_turn`：已保存的 quick_panel_reader_actions 与默认列表都按它启用和排序。

@module koplugin.book.features.animation.panel
--]]

local _ = require("gettext")

local Panel = {}

---@return BookQuickPanelAction[]
function Panel.actions()
    return {
        {
            id = "page_turn",
            title = _("翻页动画"),
            icon = "animation",
            scope = "reader",
            --- 阅读页只在翻页动画开启时显示；设置页（无 ui）始终可配置。
            ---@param ctx BookQuickPanelContext|nil
            ---@return boolean
            available = function(ctx)
                if not (ctx and ctx.ui) then
                    return true
                end
                return require("features.animation").isEnabled()
            end,
            --- 弹出风格单选，下一次翻页即生效。
            run = function()
                require("features.animation").pickStyle()
            end,
        },
    }
end

return Panel
