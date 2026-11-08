--[[--
知乎盐选账号：App 扫码，或浏览器授权 / 粘贴 Cookie。

@module koplugin.book.source.zhihu.setting
--]]

require("l10n").apply()
local CookieLogin = require("source.cookie_login")
local _ = require("gettext")

local Setting = {}

local function loggedIn()
    return require("source.zhihu.client").cookie() ~= nil
end

---@type CookieLoginSpec
local SPEC = {
    id = "zhihu",
    title = _("知乎账号"),
    cookie_title = _("知乎登录 Cookie"),
    cookie_hint = _("按键盘 F12，点「网络」，刷新网页，复制请求标头里的整段 Cookie"),
    logout_text = _("确定退出知乎账号？"),
    loggedIn = loggedIn,
    checkAsync = function(cookie, cb) require("source.zhihu.client").loginCheckAsync(cookie, cb) end,
}

function Setting.rowStatus()
    local on = CookieLogin.authorized(SPEC)
    return on and _("已登录") or _("未登录 · 点此登录"), on
end

Setting.browser = {
    domain = "www.zhihu.com",
    scope = "cookie",
    login = "https://www.zhihu.com/signin",
    check = "https://www.zhihu.com/api/v4/me",
    icon = "https://www.zhihu.com/favicon.ico",
    isAuthorized = function() return CookieLogin.authorized(SPEC) end,
    apply = function(payload, cb)
        CookieLogin.save(SPEC, CookieLogin.fromPayload(payload, "zhihu.com"), cb)
    end,
}

local function showLogin()
    require("ui/network/manager"):runWhenConnected(function()
        require("source.zhihu.qrlogin"):new(function()
            require("source.auth").ok("zhihu")
            require("source.registry").reload()
            require("ui.themes.widgets.toast"):new{ text = _("登录成功"), timeout = 2 }:show()
        end):start()
    end)
end

function Setting.rows(plugin)
    local rows = {
        CookieLogin.accountRow(SPEC, {
            subtitle = _("用知乎 App 扫一扫"),
            callback = showLogin,
        }),
        CookieLogin.browserRow(),
        CookieLogin.pasteRow(SPEC),
        require("source.review_setting").row("zhihu", plugin),
    }
    if loggedIn() then rows[#rows + 1] = CookieLogin.logoutRow(SPEC) end
    return rows
end

function Setting.login()
    showLogin()
end

return Setting
