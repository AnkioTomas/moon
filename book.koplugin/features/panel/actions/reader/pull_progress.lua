--[[-- 拉取进度快捷动作：取属主源的云端进度，不一致时询问跳转。
@module koplugin.book.features.panel.actions.reader.pull_progress
--]]

local _ = require("gettext")

---@return ReaderSessionSnapshot|nil
local function session()
    local current = require("reader.session").current()
    local source = current and current.identity and current.identity.source
    return source and type(source.getProgressAsync) == "function" and current or nil
end

---@type BookQuickPanelAction
return {
    id = "pull_progress",
    title = _("拉取进度"),
    icon = "cloud_download",
    scope = "reader",
    --- 属主源能拉进度才可用；设置页（无 ui）总能勾选。
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        return not (ctx and ctx.ui) or session() ~= nil
    end,
    run = function()
        local current = session()
        if current then require("reader.session.progress").pull(current, { manual = true }) end
    end,
}
