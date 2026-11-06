--[[--
塔读账号：只用微信扫码。登录态是扫码成功后的 Cookie。

@module source.tadu.setting
--]]

require("l10n").apply()
local _ = require("gettext")

local SOURCE_ID = "tadu"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.tadu.client").loggedIn()
end

---@param user { name: string }
local function save(user)
    local settings = require("utils.settings")
    local cfg = settings.getSource(SOURCE_ID)
    cfg.logged_in = true
    cfg.name = user.name
    settings.saveSource(SOURCE_ID)
    require("source.auth").ok(SOURCE_ID)
    require("source.registry").reload()
    require("ui.themes.widgets.toast"):new{ text = _("登录成功"), timeout = 2 }:show()
end

function Setting.rowTitle()
    return _("塔读账号")
end

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此扫码"), on
end

function Setting.open()
    require("ui/network/manager"):runWhenConnected(function()
        require("source.tadu.qrlogin"):new(save):start()
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
                subtitle = _("打开微信，扫屏幕上的二维码"),
                status = status, status_on = status_on,
                callback = function() Setting.open() end,
            })
        end,
    }
    if loggedIn() then
        rows[#rows + 1] = require("source.logout").row(SOURCE_ID, _("确定退出塔读账号？"), function()
            local settings = require("utils.settings")
            local cfg = settings.getSource(SOURCE_ID)
            cfg.cookie, cfg.logged_in, cfg.name = nil, nil, nil
            settings.saveSource(SOURCE_ID)
            require("source.tadu.client").reset()
        end)
    end
    return rows
end

Setting.login = Setting.open

return Setting
