--[[-- 推送进度快捷动作：当前位置立即推给属主源。
@module koplugin.book.features.panel.actions.reader.push_progress
--]]

local _ = require("gettext")

---@return ReaderSessionSnapshot|nil
local function session()
    local current = require("reader.session").current()
    local source = current and current.identity and current.identity.source
    return source and type(source.putProgressAsync) == "function" and current or nil
end

---@type BookQuickPanelAction
return {
    id = "push_progress",
    title = _("推送进度"),
    icon = "cloud_upload",
    scope = "reader",
    --- 属主源能上报进度才可用；设置页（无 ui）总能勾选。
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        return not (ctx and ctx.ui) or session() ~= nil
    end,
    run = function()
        local current = session()
        if current then require("reader.session.progress").push(current) end
    end,
}
