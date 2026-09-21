--[[--
番茄源设置入口。

@module koplugin.book.source.fanqie.setting
--]]

require("l10n").apply()
local _ = require("gettext")

local M = {}

function M.rowTitle()
    return _("番茄账号与登录")
end

function M.rowStatus()
    local ok = require("source.fanqie.settings"):new():is_cookie_configured()
    return ok and _("已登录") or _("未登录 · 点此扫码"), ok
end

--- 登录态变更后作废源实例并刷新桌面（设置行状态随之重建）。
---@param plugin table|nil
local function afterAuthChanged(plugin)
    require("source.registry").invalidate()
    if plugin and plugin.onSourceChanged then
        plugin:onSourceChanged()
    end
end

---@param plugin table|nil
function M.open(plugin)
    local settings = require("source.fanqie.settings"):new()
    local UI = require("ui/uimanager")
    local owner = {}
    function owner:closeBusy()
        if self.busy then UI:close(self.busy); self.busy = nil end
    end
    function owner:showBusy(text)
        self:closeBusy()
        self.busy = require("ui/widget/infomessage"):new{ text = text }
        UI:show(self.busy)
    end
    function owner:onLoginSuccess()
        afterAuthChanged(plugin)
    end
    require("ui/network/manager"):runWhenOnline(function()
        require("source.fanqie.qrlogin"):new(nil, settings, owner):start()
    end)
end

return M
