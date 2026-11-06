--[[--
得到账号：只用得到 App 扫码。登录态是扫码成功后的 Cookie。

@module source.dedao.setting
--]]

require("l10n").apply()
local _ = require("gettext")

local SOURCE_ID = "dedao"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.dedao.client").loggedIn()
end

local function save()
    local settings = require("utils.settings")
    local cfg = settings.getSource(SOURCE_ID)
    cfg.logged_in = true
    settings.saveSource(SOURCE_ID)
    require("source.auth").ok(SOURCE_ID)
    require("source.registry").reload()
    require("ui.themes.widgets.toast"):new{ text = _("登录成功"), timeout = 2 }:show()
end

function Setting.rowTitle()
    return _("得到账号")
end

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此扫码"), on
end

function Setting.open()
    require("ui/network/manager"):runWhenConnected(function()
        require("source.dedao.qrlogin"):new(save):start()
    end)
end

---@return table[]
function Setting.rows()
    local Row = require("ui.themes.widgets.row")
    local rows = {
        function(iw)
            local status, status_on = Setting.rowStatus()
            return Row.widget({
                width = iw, chevron = true, kind = "nav", icon = "account_circle",
                title = Setting.rowTitle(),
                subtitle = _("打开得到 App，扫屏幕上的二维码"),
                status = status, status_on = status_on,
                callback = function() Setting.open() end,
            })
        end,
    }
    if loggedIn() then
        rows[#rows + 1] = require("source.logout").row(SOURCE_ID, _("确定退出得到账号？"), function()
            local settings = require("utils.settings")
            local cfg = settings.getSource(SOURCE_ID)
            cfg.cookie, cfg.logged_in = nil, nil
            settings.saveSource(SOURCE_ID)
            require("source.dedao.client").reset()
        end)
    end
    return rows
end

Setting.login = Setting.open

return Setting
