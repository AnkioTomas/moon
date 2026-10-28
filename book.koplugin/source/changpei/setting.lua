--[[--
长佩源设置：登录。

长佩网页的登录态是 Cookie（PHPSESSID 等，含 HttpOnly）。没有登录态时服务端要求人机验证、不给正文。
登录三条路：扫码（长佩 App 扫，qrlogin.lua）、浏览器扩展授权（check 靠 JSON code 判定）、或在电脑浏览器登录后把请求里的 Cookie 请求头粘贴进来。
拿到 Cookie 先拉一次账号信息校验，通过才保存。

@module koplugin.book.source.changpei.setting
--]]

require("l10n").apply()
local _ = require("gettext")
local CookieLogin = require("source.cookie_login")

local SOURCE_ID = "changpei"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.changpei.client").cookie() ~= nil
end

---@type CookieLoginSpec
local SPEC = {
    id = SOURCE_ID,
    title = _("长佩账号"),
    cookie_title = _("长佩登录 Cookie"),
    cookie_hint = _("登录长佩后，从开发者工具网络面板复制请求头里的 Cookie"),
    logout_text = _("确定退出长佩账号？"),
    loggedIn = loggedIn,
    checkAsync = function(cookie, cb)
        require("source.changpei.client").userAsync(cookie, function(info, err) cb(info ~= nil, err) end)
    end,
}

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此登录"), on
end

Setting.parseCookie = CookieLogin.parse

--- 浏览器扩展登录（features/cookie）。getUserInfo 一律 HTTP 200，靠 JSON code 判登录（未登录 9996）。
Setting.browser = {
    domain = "www.gongzicp.com",
    scope = "cookie",
    login = "https://www.gongzicp.com/login/signin",
    check = "https://www.gongzicp.com/webapi/user/getUserInfo",
    check_json = { path = "code", ok = { 200 } },
    icon = "https://www.gongzicp.com/favicon.ico",
    isAuthorized = function() return CookieLogin.authorized(SPEC) end,
    apply = function(payload, cb) CookieLogin.save(SPEC, CookieLogin.fromPayload(payload, "gongzicp.com"), cb) end,
}

local function startQR()
    require("ui/network/manager"):runWhenConnected(function()
        require("source.changpei.qrlogin"):new(function(cookie) CookieLogin.verify(SPEC, cookie) end):start()
    end)
end

---@return table[]
function Setting.rows()
    local rows = { CookieLogin.accountRow(SPEC, { callback = startQR }) }
    if loggedIn() then
        rows[#rows + 1] = CookieLogin.logoutRow(SPEC)
    else
        rows[#rows + 1] = CookieLogin.pasteRow(SPEC)
    end
    return rows
end

--- 登录失效提示的「重新登录」直达入口（desktop.sync.promptLogin）。
Setting.login = startQR

return Setting
