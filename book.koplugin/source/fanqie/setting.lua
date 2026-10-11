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

function M.open()
    local settings = require("source.fanqie.settings"):new()
    local owner = {}
    function owner:closeBusy()
        if self.busy then self.busy:close(); self.busy = nil end
    end
    function owner:showBusy(text)
        self:closeBusy()
        self.busy = require("ui.themes.widgets.toast"):new{ text = text }
        self.busy:show()
    end
    function owner:onLoginSuccess()
        require("source.registry").reload()
    end
    require("ui/network/manager"):runWhenOnline(function()
        require("source.fanqie.qrlogin"):new(settings, owner):start()
    end)
end

return M
