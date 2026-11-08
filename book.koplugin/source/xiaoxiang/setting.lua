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

local function commit(cookie, account, cb)
    local Settings = require("utils.settings")
    local cfg = Settings.getSource(SOURCE_ID)
    local previous, previous_id = cfg.cookie, cfg.account_id
    local cancelled, job, dialog = false, nil, nil
    local function save(switching)
        if cancelled then return end
        if cfg.cookie ~= previous then cb(false, _("账号已变化，请重新登录")); return end
        if switching then
            local snapshot = require("reader.session").current()
            if snapshot and snapshot.identity and snapshot.identity.source_id == SOURCE_ID then snapshot.ui:onClose() end
            require("source.logout").abort(SOURCE_ID)
            cfg.cookie = nil
            Settings.saveSource(SOURCE_ID, cfg)
            require("source.registry").invalidate()
            if not require("book.store").forgetSource(SOURCE_ID) then
                cfg.cookie = previous
                Settings.saveSource(SOURCE_ID, cfg)
                require("source.registry").reload()
                cb(false, _("清除本地记录失败")); return
            end
        end
        cfg.cookie, cfg.account_id = cookie, account.id
        Settings.saveSource(SOURCE_ID, cfg)
        require("source.auth").ok(SOURCE_ID)
        require("source.registry").reload()
        cb(true)
    end
    local function compare(id)
        if id == account.id then save(false); return end
        dialog = require("ui.themes.widgets.confirm"):new{
            text = _("切换潇湘账号会清除这台设备上潇湘的书架、阅读进度、笔记和缓存，包括尚未同步的记录。不会删除远端书架。确定继续？"),
            ok_text = _("切换账号"),
            ok_callback = function() save(true) end,
            cancel_callback = function() if not cancelled then cb(false, _("已取消登录")) end end,
        }
        dialog:show()
    end
    if not account or type(account.id) ~= "string" or not account.id:match("^%d+$") then
        cb(false, _("潇湘账号标识缺失"))
    elseif not previous or previous == cookie then
        save(false)
    elseif previous_id then
        compare(previous_id)
    else
        local pending = true
        local initial = require("source.xiaoxiang.client").userAsync(previous, function(old_account, err)
            pending = false
            if cancelled then return end
            if not old_account then
                cb(false, _("无法确认旧账号，请先退出旧账号再登录") .. (err and ("：" .. err) or "")); return
            end
            compare(old_account.id)
        end)
        if pending then job = initial end
    end
    return { cancel = function()
        cancelled = true
        if job then job:cancel() end
        if dialog then dialog:close() end
    end }
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
