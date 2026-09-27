--[[-- 翻页动画风格快捷动作。
@module koplugin.book.ui.panel.actions.reader.page_turn
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
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
        -- registry 会一次性 require 全部动作：门面带 ConfirmBox 等 UI 依赖，用时再拉
        return require("patch.page_turn_animation").isEnabled()
    end,
    --- 弹出风格单选，下一次翻页即生效。
    run = function()
        require("patch.page_turn_animation").pickStyle()
    end,
}
