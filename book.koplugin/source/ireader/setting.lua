--[[--
掌阅账号：App 扫码、官网浏览器登录及 Cookie 导入（`_zypps` → usr/zysid）。

@module source.ireader.setting
--]]

require("l10n").apply()
local _ = require("gettext")
local CookieLogin = require("source.cookie_login")

local SOURCE_ID = "ireader"
local Setting = {}
local LOGIN_URL = "https://pc.ireader.com/login"

---@return boolean
local function loggedIn()
    return require("source.ireader.client").session() ~= nil
end

--- Cookie 请求头里的 `_zypps`（官网 qs 串）→ usr/zysid。
---@param header string
---@return { usr: string, zysid: string, name: string|nil, avatar: string|nil }|nil
local function userFromCookie(header)
    local Text = require("utils.text")
    local raw
    for part in tostring(header):gmatch("[^;]+") do
        local name, value = part:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
        if name == "_zypps" and value and value ~= "" then
            raw = value
            break
        end
    end
    if not raw then return nil end
    raw = Text.urlDecode(raw) or raw
    local fields = {}
    for pair in raw:gmatch("[^&]+") do
        local key, value = pair:match("^([^=]+)=(.*)$")
        if key then
            fields[Text.urlDecode(key) or key] = Text.urlDecode(value) or value
        end
    end
    local usr, zysid = fields.usr, fields.zysid
    if type(usr) ~= "string" or usr == "" or type(zysid) ~= "string" or zysid == "" then
        return nil
    end
    return { usr = usr, zysid = zysid, name = fields.name, avatar = fields.avatar }
end

---@param user table
---@return boolean ok
---@return string|nil err
local function commitUser(user)
    local settings = require("utils.settings")
    local cfg = settings.getSource(SOURCE_ID)
    if cfg.usr and cfg.usr ~= "" and cfg.usr ~= user.usr then
        return false, _("请先退出当前账号，再登录其他账号")
    end
    cfg.usr = user.usr
    cfg.zysid = user.zysid
    cfg.name = user.name
    cfg.avatar = user.avatar
    settings.saveSource(SOURCE_ID)
    require("source.auth").ok(SOURCE_ID)
    require("source.registry").reload()
    return true
end

---@param user table
local function save(user)
    local ok, err = commitUser(user)
    if not ok then
        require("ui.themes.widgets.toast"):new{ text = err, timeout = 3 }:show()
        return
    end
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
    require("source.ireader.qrlogin"):new(save):start()
end

local SPEC = {
    id = SOURCE_ID, title = _("掌阅账号"), cookie_title = _("掌阅登录 Cookie"),
    cookie_hint = _("按键盘 F12，点「网络」，刷新网页，复制请求标头里的整段 Cookie（须含 _zypps）"),
    logout_text = _("确定退出掌阅账号？"),
    loggedIn = loggedIn,
    checkAsync = function(cookie, cb)
        local user = userFromCookie(cookie)
        if not user then return cb(false, _("没有读到 _zypps（usr/zysid）")) end
        return require("source.ireader.client").checkSessionAsync(user, function(ok, err)
            if not ok then return cb(false, err or _("登录失败")) end
            cb(true, nil, user)
        end)
    end,
    commit = function(_cookie, account, cb)
        local ok, err = commitUser(account)
        cb(ok, err)
    end,
    clear = function(cfg)
        cfg.usr, cfg.zysid, cfg.name, cfg.avatar = nil, nil, nil, nil
    end,
}

--- 扩展 payload 里取 `_zypps`（pc.ireader.com / .zhangyue.com 任一即可）。
---@param payload table
---@return string
local function cookieFromPayload(payload)
    for _idx, cookie in ipairs(type(payload.cookies) == "table" and payload.cookies or {}) do
        local host = type(cookie) == "table" and type(cookie.domain) == "string"
            and cookie.domain:gsub("^%.", ""):lower()
        if host and cookie.name == "_zypps" and type(cookie.value) == "string" and cookie.value ~= "" then
            if host == "ireader.com" or host:match("%.ireader%.com$")
                or host == "zhangyue.com" or host:match("%.zhangyue%.com$") then
                return "_zypps=" .. cookie.value
            end
        end
    end
    return ""
end

Setting.browser = {
    domain = "pc.ireader.com", scope = "cookie", login = LOGIN_URL,
    check = "https://pc.ireader.com/",
    icon = "https://static-efe-front-h.zhangyuecdn.com/sfm-production/logos/bf7fe8aa-35e2-4961-9e1a-e2a095950ff2.png",
    isAuthorized = function() return CookieLogin.authorized(SPEC) end,
    apply = function(payload, cb)
        CookieLogin.save(SPEC, cookieFromPayload(payload), cb)
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
                subtitle = _("在掌阅 App「我的」页右上角使用扫一扫"),
                status = status, status_on = status_on,
                callback = function() Setting.open() end,
            })
        end,
        CookieLogin.browserRow(),
        CookieLogin.pasteRow(SPEC),
    }
    if loggedIn() then
        rows[#rows + 1] = CookieLogin.logoutRow(SPEC)
    end
    return rows
end

Setting.login = Setting.open
Setting.userFromCookie = userFromCookie

return Setting
