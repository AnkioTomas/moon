--[[--
网易云阅读电脑端账号：手机号密码、微信扫码、电脑浏览器 Cookie。

@module source.netease.setting
--]]

local _ = require("l10n").get("source.netease")
local CookieLogin = require("source.cookie_login")

local SOURCE_ID = "netease"
local Setting = {}
local LOGIN_URL = "https://yuedu.163.com/loginForm.do?targetUrl=https%3A%2F%2Fyuedu.163.com%2Fmyinfor.do"

local function loggedIn()
    return require("source.netease.client").loggedIn()
end

local SPEC = {
    id = SOURCE_ID,
    title = _("网易云阅读账号"),
    cookie_title = _("网易云阅读登录 Cookie"),
    cookie_hint = _("按键盘 F12，点「网络」，刷新网页，复制请求标头里的整段 Cookie"),
    logout_text = _("确定退出网易云阅读账号？"),
    loggedIn = loggedIn,
    checkAsync = function(cookie, cb)
        return require("source.netease.client").loginCheckAsync(cookie, cb)
    end,
    store = function(cfg, cookie)
        cfg.cookie, cfg.logged_in, cfg.csrf = cookie, true, nil
    end,
    clear = function(cfg)
        cfg.cookie, cfg.csrf, cfg.logged_in = nil, nil, nil
    end,
}

Setting.browser = {
    domain = "yuedu.163.com",
    scope = "cookie",
    login = LOGIN_URL,
    check = "https://yuedu.163.com/myinfor.do",
    icon = "https://yuedust.yuedu.126.net/favicon.ico",
    isAuthorized = function() return CookieLogin.authorized(SPEC) end,
    apply = function(payload, cb)
        CookieLogin.save(SPEC, CookieLogin.fromPayload(payload, "163.com"), cb)
    end,
}

local function connected()
    if require("ui/network/manager"):isConnected() then return true end
    require("ui.themes.widgets.toast"):new{ text = _("网络不可用，请先连接 Wi-Fi"), timeout = 3 }:show()
    return false
end

local function onLogin()
    require("source.registry").reload()
    require("ui.themes.widgets.toast"):new{ text = _("登录成功"), timeout = 2 }:show()
end

local function showLogin()
    local Toast = require("ui.themes.widgets.toast")
    local session = require("source.netease.auth").new()
    local closed, busy, verification, waiting = false, false, nil, nil
    local dialog
    local function submit(phone, password, code)
        if closed or busy or not connected() then return end
        busy = true
        waiting = require("ui.themes.widgets.progress_dialog"):new{
            title = _("网易云阅读账号"), text = _("正在登录…"),
            on_cancel = function()
                session:cancel()
                busy = false
                waiting:close()
                waiting = nil
            end,
        }
        waiting:show()
        session:passwordAsync(phone, password, code, function(ok, err, needs_code)
            busy = false
            waiting:close()
            waiting = nil
            if closed then return end
            if ok then dialog:close(); onLogin(); return end
            Toast:new{ text = err or _("登录失败"), timeout = 3 }:show()
            if needs_code then
                verification = require("source.netease.verify").new(session, function(value)
                    verification = nil
                    if value then submit(phone, password, value) end
                end)
            end
        end)
    end
    dialog = require("ui.themes.widgets.input"):new{
        title = _("网易云阅读账号"),
        keep_open = true,
        fields = {
            { label = _("手机号"), text = "", input_type = "number" },
            { label = _("密码"), text = "", text_type = "password" },
        },
        ok_text = _("登录"),
        close_callback = function()
            closed = true
            if verification then verification:cancel() end
            session:cancel()
            if waiting then waiting:close(); waiting = nil end
        end,
        callback = function(phone, password)
            phone = require("utils.text").trim(phone)
            if #phone ~= 11 or not phone:match("^%d+$") then
                Toast:new{ text = _("请填写正确的手机号"), timeout = 3 }:show()
                return
            end
            if password == "" then
                Toast:new{ text = _("请填写密码"), timeout = 3 }:show()
                return
            end
            submit(phone, password)
        end,
    }
    dialog:show()
end

function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此登录"), on
end

function Setting.rows()
    local Row = require("ui.themes.widgets.row")
    local rows = {
        function(iw)
            local status, status_on = Setting.rowStatus()
            return Row.widget({
                width = iw, chevron = true, kind = "nav", icon = "account_circle",
                title = _("网易云阅读账号"), subtitle = _("手机号密码登录"),
                status = status, status_on = status_on, callback = showLogin,
            })
        end,
        function(iw)
            return Row.widget({
                width = iw, chevron = true, kind = "nav", icon = "qr_code",
                title = _("微信扫码登录"), subtitle = _("打开微信，扫屏幕上的二维码"),
                callback = function()
                    if connected() then require("source.netease.qrlogin"):new(onLogin):start() end
                end,
            })
        end,
        CookieLogin.browserRow(),
        CookieLogin.pasteRow(SPEC),
    }
    if loggedIn() then rows[#rows + 1] = CookieLogin.logoutRow(SPEC) end
    return rows
end

Setting.login = showLogin

return Setting
