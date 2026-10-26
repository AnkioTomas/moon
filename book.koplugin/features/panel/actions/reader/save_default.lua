--[[-- 保存为默认配置快捷动作：当前排版与字体成为全局默认（所有书下次打开生效）。
@module koplugin.book.features.panel.actions.reader.save_default
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "save_default",
    title = _("保存为默认配置"),
    icon = "save",
    scope = "reader",
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        local ui = ctx and ctx.ui
        return not ui or (ui.document ~= nil and ui.document.configurable ~= nil)
    end,
    ---@param ctx BookQuickPanelContext
    run = function(ctx)
        local ui = ctx.ui
        require("ui.themes.widgets.confirm"):new{
            text = _("将当前排版和字体保存为所有书的默认配置？下次打开时生效（含章节源）。"),
            ok_text = _("保存"),
            ok_callback = function()
                local ok = require("reader.prefs").saveDefaults(ui)
                require("ui.themes.widgets.toast"):new{
                    text = ok and _("已保存为默认配置") or _("当前文档不支持保存默认配置"),
                    timeout = 2,
                }:show()
            end,
        }:show()
    end,
}
