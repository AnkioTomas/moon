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
        self.busy = require("ui.themes.widgets.progress_dialog"):new{
            title = _("番茄扫码登录"), text = text, dismissable = false,
        }
        self.busy:show()
    end
    function owner:onLoginSuccess()
        require("source.registry").reload()
    end
    require("ui/network/manager"):runWhenConnected(function()
        require("source.fanqie.qrlogin"):new(settings, owner):start()
    end)
end

--- 设置页行：账号（扫码）与阅读选项。
---@param plugin table|nil
---@return table[]
function M.rows(plugin)
    local Row = require("ui.themes.widgets.row")
    return {
        function(iw)
            local status, status_on = M.rowStatus()
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "account_circle",
                title = M.rowTitle(), status = status, status_on = status_on,
                callback = function() M.open() end })
        end,
        function(iw)
            local settings = require("source.fanqie.settings"):new()
            local on = settings:get("show_paragraph_reviews", false) == true
            return Row.widget({ width = iw, chevron = false, kind = "toggle", icon = "forum",
                title = _("显示段评"), subtitle = _("阅读时给有他人段评的段落末尾画线，点按查看；需联网"),
                status = on and _("开") or _("关"), status_on = on,
                callback = function()
                    settings:set("show_paragraph_reviews", not on)
                    settings:flush()
                    if plugin and plugin.desktop then plugin.desktop:updateView() end
                end })
        end,
    }
end

return M
