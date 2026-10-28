--[[--
起点源设置：登录。

起点登录要过验证码，墨水屏上做不了；登录态就是手机站 Cookie，两种进法：
远程管理里的「浏览器登录」（浏览器扩展交 Cookie），或在电脑浏览器登录后把 Cookie 请求头粘贴进来。
两条路都先拉一次书架页校验，通过才保存。Cookie 里必须有 _csrfToken，否则书架接口 403。

@module koplugin.book.source.qidian.setting
--]]

require("l10n").apply()
local _ = require("gettext")
local CookieLogin = require("source.cookie_login")

local SOURCE_ID = "qidian"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.qidian.client").cookie() ~= nil
end

---@type CookieLoginSpec
local SPEC = {
    id = SOURCE_ID,
    title = _("起点账号"),
    cookie_title = _("起点登录 Cookie"),
    cookie_hint = _("在电脑浏览器登录起点手机版后粘贴 Cookie"),
    logout_text = _("确定退出起点账号？"),
    loggedIn = loggedIn,
    checkAsync = function(cookie, cb) require("source.qidian.client").loginCheckAsync(cookie, cb) end,
}

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此登录"), on
end

Setting.parseCookie = CookieLogin.parse

--- 浏览器扩展交来的 payload.cookies → Cookie 请求头；只收起点站点的 Cookie。
---@param payload table
---@return string
function Setting.fromPayload(payload)
    return CookieLogin.fromPayload(payload, "qidian.com")
end

--- 浏览器扩展登录（features/cookie）。
Setting.browser = {
    domain = "m.qidian.com",
    scope = "cookie",
    -- 扩展要求 login/check 与 domain 同主机。未登录时书架页自己 302 到 passport，登录完回到本站再采集。
    login = "https://m.qidian.com/bookshelf/my/",
    check = "https://m.qidian.com/bookshelf/my/",
    icon = "https://imgservices-1252317822.image.myqcloud.com/coco/s03102023/b7b10602.w663ve.ico",
    isAuthorized = function() return CookieLogin.authorized(SPEC) end,
    apply = function(payload, cb) CookieLogin.save(SPEC, Setting.fromPayload(payload), cb) end,
}

---@return table[]
function Setting.rows(plugin)
    local rows = {
        CookieLogin.accountRow(SPEC, { subtitle = _("也可在「远程管理」里用浏览器授权登录") }),
        require("source.review_setting").row(SOURCE_ID, plugin),
    }
    if loggedIn() then rows[#rows + 1] = CookieLogin.logoutRow(SPEC) end
    return rows
end

--- 登录失效提示的「重新登录」直达入口（desktop.sync.promptLogin）。
function Setting.login()
    CookieLogin.prompt(SPEC)
end

return Setting
