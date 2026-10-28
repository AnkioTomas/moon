--[[--
潇湘源设置：登录。

潇湘账号在新站 www.xxsypro.com（阅文通行证，只有 QQ / 微信 / 阅文账号，没有扫码）。登录态是网页 Cookie：
浏览器扩展授权（check 靠 personal 接口 data.isLogin），或在电脑浏览器登录后把请求里的 Cookie 请求头粘贴进来。拿到 Cookie 先校验再保存。

@module koplugin.book.source.xiaoxiang.setting
--]]

require("l10n").apply()
local _ = require("gettext")
local CookieLogin = require("source.cookie_login")

local SOURCE_ID = "xiaoxiang"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.xiaoxiang.client").cookie() ~= nil
end

---@type CookieLoginSpec
local SPEC = {
    id = SOURCE_ID,
    title = _("潇湘账号"),
    cookie_title = _("潇湘登录 Cookie"),
    cookie_hint = _("登录 www.xxsypro.com 后，从开发者工具网络面板复制请求头里的 Cookie"),
    logout_text = _("确定退出潇湘账号？"),
    loggedIn = loggedIn,
    checkAsync = function(cookie, cb)
        require("source.xiaoxiang.client").userAsync(cookie, function(info, err) cb(info ~= nil, err) end)
    end,
}

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此登录"), on
end

Setting.parseCookie = CookieLogin.parse

--- 浏览器扩展登录（features/cookie）。personal 接口一律 code 0，靠 data.isLogin 判登录。
Setting.browser = {
    domain = "www.xxsypro.com",
    scope = "cookie",
    login = "https://www.xxsypro.com/",
    check = "https://www.xxsypro.com/api/user/auth/personal",
    check_json = { path = "data.isLogin", ok = { 1 } },
    icon = "https://www.xxsypro.com/favicon.ico",
    isAuthorized = function() return CookieLogin.authorized(SPEC) end,
    apply = function(payload, cb) CookieLogin.save(SPEC, CookieLogin.fromPayload(payload, "xxsypro.com"), cb) end,
}

---@return table[]
function Setting.rows()
    local rows = { CookieLogin.accountRow(SPEC) }
    if loggedIn() then rows[#rows + 1] = CookieLogin.logoutRow(SPEC) end
    return rows
end

--- 登录失效提示的「重新登录」直达入口（desktop.sync.promptLogin）。
function Setting.login()
    CookieLogin.prompt(SPEC)
end

return Setting
