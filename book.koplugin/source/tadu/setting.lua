--[[--
塔读账号：微信扫码、官网浏览器登录及 Cookie 导入。

@module source.tadu.setting
--]]

require("l10n").apply()
local _ = require("gettext")
local CookieLogin = require("source.cookie_login")

local SOURCE_ID = "tadu"
local Setting = {}
local LOGIN_URL = "https://www.tadu.com/v3/loginpage"

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
    if not require("ui/network/manager"):isConnected() then
        require("ui.themes.widgets.toast"):new{ text = _("网络不可用，请先连接 Wi-Fi"), timeout = 3 }:show()
        return
    end
    require("source.tadu.qrlogin"):new(save):start()
end

local SPEC = {
    id = SOURCE_ID, title = _("塔读账号"), cookie_title = _("塔读登录 Cookie"),
    cookie_hint = _("按键盘 F12，点「网络」，刷新网页，复制请求标头里的整段 Cookie"),
    logout_text = _("确定退出塔读账号？"),
    loggedIn = loggedIn,
    checkAsync = require("source.tadu.client").loginCheckAsync,
    store = function(cfg, cookie) cfg.cookie, cfg.logged_in = cookie, true end,
    clear = function(cfg)
        cfg.cookie, cfg.logged_in, cfg.name = nil, nil, nil
        cfg.read_cookie, cfg.read_cookie_for = nil, nil
    end,
}

Setting.browser = {
    domain = "www.tadu.com", scope = "cookie", login = LOGIN_URL,
    check = "https://www.tadu.com/tadu/space/reader",
    isAuthorized = function() return CookieLogin.authorized(SPEC) end,
    apply = function(payload, cb)
        CookieLogin.save(SPEC, CookieLogin.fromPayload(payload, "tadu.com"), cb)
    end,
}

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
        function(iw)
            return Row.widget({
                width = iw, chevron = true, kind = "nav", icon = "language",
                title = _("电脑浏览器登录"),
                subtitle = _("账号密码和短信验证码请在官网完成"),
                callback = function()
                    require("ui.themes.widgets.text_viewer"):new{
                        title = _("电脑浏览器登录"),
                        text = CookieLogin.relogin(_("塔读"), LOGIN_URL, _("塔读登录 Cookie")),
                    }:show()
                end,
            })
        end,
        CookieLogin.pasteRow(SPEC),
    }
    local cookie = require("source.tadu.client").cookie()
    if type(cookie) == "string" and cookie ~= "" then
        rows[#rows + 1] = CookieLogin.logoutRow(SPEC)
    end
    return rows
end

Setting.login = Setting.open

return Setting
