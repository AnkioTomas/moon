--[[--
掌阅账号：只用掌阅 App 扫码。登录态是 usr + zysid，没有 Cookie。

@module source.ireader.setting
--]]

require("l10n").apply()
local _ = require("gettext")

local SOURCE_ID = "ireader"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.ireader.client").session() ~= nil
end

---@param user table
local function save(user)
    local settings = require("utils.settings")
    local cfg = settings.getSource(SOURCE_ID)
    cfg.usr = user.usr
    cfg.zysid = user.zysid
    cfg.name = user.name
    cfg.avatar = user.avatar
    settings.saveSource(SOURCE_ID)
    require("source.auth").ok(SOURCE_ID)
    require("source.registry").reload()
    require("ui.themes.widgets.toast"):new{ text = _("登录成功"), timeout = 2 }:show()
end

function Setting.rowTitle()
    return _("掌阅账号")
end

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此扫码"), on
end

function Setting.open()
    require("ui/network/manager"):runWhenConnected(function()
        require("source.ireader.qrlogin"):new(save):start()
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
                subtitle = _("在掌阅 App「我的」页右上角使用扫一扫"),
                status = status, status_on = status_on,
                callback = function() Setting.open() end,
            })
        end,
    }
    if loggedIn() then
        rows[#rows + 1] = require("source.logout").row(SOURCE_ID, _("确定退出掌阅账号？"), function()
            local settings = require("utils.settings")
            local cfg = settings.getSource(SOURCE_ID)
            cfg.usr, cfg.zysid, cfg.name, cfg.avatar = nil, nil, nil, nil
            settings.saveSource(SOURCE_ID)
        end)
    end
    return rows
end

Setting.login = Setting.open

return Setting
