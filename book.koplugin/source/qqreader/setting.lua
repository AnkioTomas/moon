--[[--
QQ阅读源设置：登录。

设备上扫阅文二维码（QQ阅读或起点 App）。浏览器扩展绑定保留：login/check 必须是
book.qq.com 下的 HTTPS，不能指到 passport。书架页未登录也是 200，扩展会立刻回传 Cookie。
扫码、粘贴、扩展三条路都先打 /api/user/homepage，code 不是 0 就不保存。

@module koplugin.book.source.qqreader.setting
--]]

require("l10n").apply()
local _ = require("gettext")
local CookieLogin = require("source.cookie_login")

local SOURCE_ID = "qqreader"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.qqreader.client").cookie() ~= nil
end

---@type CookieLoginSpec
local SPEC = {
    id = SOURCE_ID,
    title = _("QQ阅读账号"),
    cookie_title = _("QQ阅读登录 Cookie"),
    cookie_hint = _("在电脑浏览器登录 QQ阅读后粘贴 Cookie"),
    logout_text = _("确定退出 QQ阅读账号？"),
    loggedIn = loggedIn,
    checkAsync = function(cookie, cb) require("source.qqreader.client").loginCheckAsync(cookie, cb) end,
}

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此扫码"), on
end

Setting.parseCookie = CookieLogin.parse

--- 浏览器扩展交来的 payload.cookies → Cookie 请求头；只收 QQ阅读站点的 Cookie。
---@param payload table
---@return string
function Setting.fromPayload(payload)
    return CookieLogin.fromPayload(payload, "qq.com")
end

--- 浏览器扩展登录（features/cookie）。
Setting.browser = {
    domain = "book.qq.com",
    scope = "cookie",
    -- 必须是 domain 下的 HTTPS。未登录书架页不跳 passport，校验在 apply 里打账号接口。
    login = "https://book.qq.com/book-shelf",
    check = "https://book.qq.com/book-shelf",
    icon = "https://imgservices-1252317822.file.myqcloud.com/image/090120210101409/3a5c39e0.ico",
    isAuthorized = function() return CookieLogin.authorized(SPEC) end,
    apply = function(payload, cb) CookieLogin.save(SPEC, Setting.fromPayload(payload), cb) end,
}

local function startQR()
    require("ui/network/manager"):runWhenConnected(function()
        require("source.qqreader.qrlogin"):new(function(cookie) CookieLogin.verify(SPEC, cookie) end):start()
    end)
end

---@return table[]
function Setting.rows()
    local rows = { CookieLogin.accountRow(SPEC, { callback = startQR, off_text = _("未登录 · 点此扫码") }) }
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
