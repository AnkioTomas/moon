--[[-- 手动把本机阅读进度推到云端（仅 Kavita 页级源）。
@module koplugin.book.ui.panel.actions.reader.push_progress
--]]

local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "push_progress",
    title = _("推送进度"),
    icon = "upload",
    scope = "reader",
    -- Kavita 的书里恒常显示，不依赖面板「阅读快捷面板」的勾选（否则旧设备列表里没有它）。
    always_visible = true,
    --- 仅 Kavita，且设置页必须算可用（否则勾选不上）。
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        if not (ctx and ctx.ui) then
            return true
        end
        local session = require("ui.reader.session").current()
        local identity = session and session.identity
        return identity ~= nil and identity.source_id == "kavita"
    end,
    ---@param _ BookQuickPanelContext
    run = function()
        local session = require("ui.reader.session").current()
        if not session then return end
        require("book.progress").push(session)
    end,
}
