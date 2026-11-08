--[[--
豆瓣阅读账号：App 扫码或电脑浏览器 Cookie。登录态是 read.douban.com 的 Cookie 和用户编号。

@module source.douban.setting
--]]

local _ = require("l10n").get("source.douban")
local CookieLogin = require("source.cookie_login")

local SOURCE_ID = "douban"
local Setting = {}
local LOGIN_URL = "https://read.douban.com/oidc/login"

---@return boolean
local function loggedIn()
    return require("source.douban.client").loggedIn()
end

---@param user { id: string, name: string }
local function save(user)
    require("source.auth").ok(SOURCE_ID)
    require("source.registry").reload()
    local name = user.name ~= "" and user.name or _("已登录")
    require("ui.themes.widgets.toast"):new{ text = name, timeout = 2 }:show()
end

local SPEC = {
    id = SOURCE_ID,
    title = _("豆瓣阅读账号"),
    cookie_title = _("豆瓣阅读登录 Cookie"),
    cookie_hint = _("按键盘 F12，点「网络」，刷新网页，复制请求标头里的整段 Cookie"),
    logout_text = _("确定退出豆瓣阅读账号？"),
    loggedIn = loggedIn,
    checkAsync = function(cookie, cb)
        local login = require("source.douban.client").newLogin(cookie)
        return login:checkCookieAsync(function(ok, err, user)
            cb(ok, err, user and { user = user, login = login })
        end)
    end,
    commit = function(_cookie, candidate, cb)
        local ok, err = candidate.login:commit(candidate.user)
        if ok then
            require("source.auth").ok(SOURCE_ID)
            require("source.registry").reload()
        end
        cb(ok == true, err)
    end,
}

Setting.browser = {
    domain = "read.douban.com",
    scope = "cookie",
    login = LOGIN_URL,
    check = "https://read.douban.com/",
    icon = "https://static.arkread.com/ark/pics/favicon/v6/favicon.10c09c23.ico",
    isAuthorized = function() return CookieLogin.authorized(SPEC) end,
    apply = function(payload, cb)
        local cookies = {}
        for _idx, cookie in ipairs(type(payload.cookies) == "table" and payload.cookies or {}) do
            local domain = type(cookie.domain) == "string" and cookie.domain:gsub("^%.", ""):lower()
            if domain == "douban.com" or domain == "read.douban.com" then cookies[#cookies + 1] = cookie end
        end
        return CookieLogin.save(SPEC, CookieLogin.fromPayload({ cookies = cookies }, "douban.com"), cb)
    end,
}

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
    require("source.douban.qrlogin"):new(save):start()
end

---@param plugin table|nil
---@return table[]
function Setting.rows(plugin)
    local Row = require("ui.themes.widgets.row")
    local rows = {
        function(iw)
            local status, status_on = Setting.rowStatus()
            return Row.widget({
                width = iw, chevron = true, kind = "nav", icon = "account_circle",
                title = SPEC.title,
                subtitle = _("打开豆瓣阅读 App，扫屏幕上的二维码"),
                status = status, status_on = status_on,
                callback = function() Setting.open() end,
            })
        end,
    }
    rows[#rows + 1] = function(iw)
        return Row.widget({
            width = iw, chevron = true, kind = "nav", icon = "sms",
            title = _("手机号验证码登录"),
            callback = function() require("source.douban.phone_login"):new(save):start() end,
        })
    end
    rows[#rows + 1] = CookieLogin.browserRow()
    rows[#rows + 1] = CookieLogin.pasteRow(SPEC)
    rows[#rows + 1] = require("source.category_setting").row(SOURCE_ID, plugin)
    rows[#rows + 1] = require("source.review_setting").row(SOURCE_ID, plugin)
    if loggedIn() then
        rows[#rows + 1] = require("source.logout").row(SOURCE_ID, _("确定退出豆瓣阅读账号？"), function()
            local settings = require("utils.settings")
            local cfg = settings.getSource(SOURCE_ID)
            cfg.cookie, cfg.user_id, cfg.name, cfg.logged_in = nil, nil, nil, nil
            settings.saveSource(SOURCE_ID)
            require("source.douban.client").reset()
        end)
    end
    return rows
end

Setting.login = Setting.open

return Setting
