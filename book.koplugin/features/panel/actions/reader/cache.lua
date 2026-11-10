--[[-- 缓存快捷动作：复用详情页章节缓存（范围选择 + 进度弹窗）。
只在连续章节阅读显示；全书模式与订阅（ephemeral）不出现。
@module koplugin.book.features.panel.actions.reader.cache
--]]

local _ = require("gettext")

---@param identity BookIdentity
---@return table
local function bookOf(identity)
    local book = identity.book
    if book then return book end
    return { source_id = identity.source_id, stable_id = identity.stable_id }
end

---@return ReaderSessionSnapshot|nil, table|nil
local function cacheableSession()
    local session = require("reader.session")
    if not session.isChapterMode() then return nil end
    local current = session.current()
    local identity = current and current.identity
    if not identity or identity.ephemeral then return nil end
    local book = bookOf(identity)
    if not require("desktop.detail.cache").supported(book, identity.source) then return nil end
    return current, book
end

---@type BookQuickPanelAction
return {
    id = "cache",
    title = _("缓存"),
    icon = "download",
    scope = "reader",
    --- 章节源支持缓存才可用；设置页（无 ui）总能勾选。
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        return not (ctx and ctx.ui) or cacheableSession() ~= nil
    end,
    run = function()
        local current, book = cacheableSession()
        if not current or not book then return end
        require("desktop.detail.cache").chooseRange(book, current.identity.source)
    end,
}
