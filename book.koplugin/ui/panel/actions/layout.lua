--[[-- 阅读排版快捷动作。
@module koplugin.book.ui.panel.actions.layout
--]]

local Layout = require("ui.reader.layout")
local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "layout",
    title = _("排版"),
    icon = "article",
    scope = "reader",
    keep_open = true,
    --- 当前文档支持 CRE 排版调整时显示。
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        return Layout.isReflowable(ctx and ctx.ui)
    end,
    --- 已套用阅读风格预设时高亮。
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    active = function(ctx)
        return Layout.matchId(ctx and ctx.ui) ~= "off"
    end,
    --- 打开阅读风格与更多排版入口。
    ---@param ctx BookQuickPanelContext
    ---@return void
    run = function(ctx)
        Layout.showMenu(ctx.ui)
    end,
}
