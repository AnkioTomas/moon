--[[--
起点源设置：登录。

优先在设备上展示阅文二维码，用起点或 QQ阅读 App 扫码；保留浏览器扩展与手动 Cookie 导入。
拿到登录态先拉书架页校验，通过才保存。Cookie 里的 _csrfToken 与请求参数同值。

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
    cookie_hint = _("按键盘 F12，点「网络」，刷新网页，复制请求标头里的整段 Cookie"),
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

local function startQR()
    require("ui/network/manager"):runWhenConnected(function()
        require("source.yuewen_qr"):new({
            app_id = "13", area_id = "31", return_url = "https://m.qidian.com/",
            referer = "https://passport.qidian.com/mobile/login",
            title = _("起点扫码登录"), caption = _("用 QQ阅读或起点 App 扫一扫"),
        }, function(cookie)
            CookieLogin.verify(SPEC, cookie .. "; _csrfToken=" .. require("utils.random").hex(16))
        end):start()
    end)
end

---@return table[]
function Setting.rows(plugin)
    local rows = {
        CookieLogin.accountRow(SPEC, { callback = startQR, off_text = _("未登录 · 点此扫码") }),
        require("source.review_setting").row(SOURCE_ID, plugin),
        require("source.category_setting").row(SOURCE_ID, plugin),
    }
    if loggedIn() then rows[#rows + 1] = CookieLogin.logoutRow(SPEC) end
    rows[#rows + 1] = CookieLogin.pasteRow(SPEC)
    return rows
end

--- 登录失效提示的「重新登录」直达入口（desktop.sync.promptLogin）。
Setting.login = startQR

return Setting
