--[[--
潇湘源设置：登录。

潇湘新站 www.xxsypro.com 使用阅文通行证：设备上展示 App 扫码，保留浏览器扩展与手动 Cookie 导入。
拿到 Cookie 先用 personal 接口的 data.isLogin 校验，通过才保存。

@module koplugin.book.source.xiaoxiang.setting
--]]

local _ = require("l10n").get("source.xiaoxiang")
local CookieLogin = require("source.cookie_login")

local SOURCE_ID = "xiaoxiang"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.xiaoxiang.client").cookie() ~= nil
end

local function commit(cookie, account, cb, current)
    if not account or type(account.id) ~= "string" or not account.id:match("^%d+$") then
        cb(false, _("潇湘账号标识缺失")); return
    end
    return CookieLogin.commitAccount(SOURCE_ID, cookie, account.id, cb, current)
end

---@type CookieLoginSpec
local SPEC = {
    id = SOURCE_ID,
    title = _("潇湘账号"),
    cookie_title = _("潇湘登录 Cookie"),
    cookie_hint = _("按键盘 F12，点「网络」，刷新网页，复制请求标头里的整段 Cookie"),
    logout_text = _("确定退出潇湘账号？"),
    loggedIn = loggedIn,
    checkAsync = function(cookie, cb)
        local Client = require("source.xiaoxiang.client")
        local previous = Client.cookie()
        return Client.userAsync(cookie, function(info, err)
            if Client.cookie() ~= previous then cb(false, _("账号已变化，请重新登录")); return end
            cb(info ~= nil, err, info)
        end)
    end,
    commit = commit,
    clear = function(cfg) cfg.cookie, cfg.account_id = nil, nil end,
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
    apply = function(payload, cb) return CookieLogin.save(SPEC, CookieLogin.fromPayload(payload, "xxsypro.com"), cb) end,
}

local function startQR()
    require("ui/network/manager"):runWhenConnected(function()
        require("source.yuewen_qr"):new({
            app_id = "57", area_id = "5", return_url = "https://www.xxsypro.com/",
            referer = "https://passport.yuewen.com/yuewen.html",
            title = _("潇湘扫码登录"), caption = _("用 QQ阅读或起点 App 扫一扫"),
        }, function(cookie) CookieLogin.verify(SPEC, cookie) end):start()
    end)
end

---@return table[]
function Setting.rows()
    local rows = {
        CookieLogin.accountRow(SPEC, { callback = startQR, off_text = _("未登录 · 点此扫码") }),
        CookieLogin.browserRow(),
        CookieLogin.pasteRow(SPEC),
    }
    if loggedIn() then rows[#rows + 1] = CookieLogin.logoutRow(SPEC) end
    return rows
end

--- 登录失效提示的「重新登录」直达入口（desktop.sync.promptLogin）。
Setting.login = startQR

return Setting
