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
            text = _("切换 QQ阅读账号会清除这台设备上 QQ阅读的书架、阅读进度、笔记和缓存，包括尚未同步的记录。不会删除远端书架。确定继续？"),
            ok_text = _("切换账号"),
            ok_callback = function() save(true) end,
            cancel_callback = function() if not cancelled then cb(false, _("已取消登录")) end end,
        }
        dialog:show()
    end
    if not account or type(account.id) ~= "string" or not account.id:match("^%d+$") then
        cb(false, _("QQ阅读账号标识缺失"))
    elseif not previous or previous == cookie then
        save(false)
    elseif previous_id then
        compare(previous_id)
    else
        local pending = true
        local check = require("source.qqreader.client").loginCheckAsync(previous, function(ok, err, old_account)
            pending = false
            if cancelled then return end
            if not ok or not old_account then
                cb(false, _("无法确认旧账号，请先退出旧账号再登录") .. (err and ("：" .. err) or "")); return
            end
            compare(old_account.id)
        end)
        if pending then job = check end
    end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
        if dialog then dialog:close() end
    end }
end

---@type CookieLoginSpec
local SPEC = {
    id = SOURCE_ID,
    title = _("QQ阅读账号"),
    cookie_title = _("QQ阅读登录 Cookie"),
    cookie_hint = _("按键盘 F12，点「网络」，刷新网页，复制请求标头里的整段 Cookie"),
    logout_text = _("确定退出 QQ阅读账号？"),
    loggedIn = loggedIn,
    checkAsync = require("source.qqreader.client").loginCheckAsync,
    commit = commit,
    clear = function(cfg) cfg.cookie, cfg.account_id = nil, nil end,
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
    apply = function(payload, cb) return CookieLogin.save(SPEC, Setting.fromPayload(payload), cb) end,
}

local function startQR()
    require("ui/network/manager"):runWhenConnected(function()
        require("source.yuewen_qr"):new({
            app_id = "1450000220", area_id = "1", return_url = "https://book.qq.com/",
            referer = "https://login.book.qq.com/login.html",
            title = _("QQ阅读扫码登录"), caption = _("用 QQ阅读或起点 App 扫一扫"),
        }, function(cookie) CookieLogin.verify(SPEC, cookie) end):start()
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
