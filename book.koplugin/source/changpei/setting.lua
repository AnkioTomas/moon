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
        cfg.cookie, cfg.account_id = cookie, tostring(account.uid)
        Settings.saveSource(SOURCE_ID, cfg)
        require("source.auth").ok(SOURCE_ID)
        require("source.registry").reload()
        cb(true)
    end
    local function compare(id)
        if tostring(id) == tostring(account.uid) then save(false); return end
        dialog = require("ui.themes.widgets.confirm"):new{
            text = _("切换长佩账号会清除这台设备上长佩的书架、阅读进度、笔记和缓存，包括尚未同步的记录。不会删除远端书架。确定继续？"),
            ok_text = _("切换账号"),
            ok_callback = function() save(true) end,
            cancel_callback = function() if not cancelled then cb(false, _("已取消登录")) end end,
        }
        dialog:show()
    end
    if not account or not tonumber(account.uid) or tonumber(account.uid) <= 0 then
        cb(false, _("长佩账号标识缺失"))
    elseif not previous or previous == cookie then
        save(false)
    elseif previous_id then
        compare(previous_id)
    else
        local pending = true
        local initial = require("source.changpei.client").userAsync(previous, function(old_account, err)
            pending = false
            if cancelled then return end
            if not old_account then
                cb(false, _("无法确认旧账号，请先退出旧账号再登录") .. (err and ("：" .. err) or "")); return
            end
            compare(old_account.uid)
        end)
        if pending then job = initial end
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
    title = _("长佩账号"),
    cookie_title = _("长佩登录 Cookie"),
    cookie_hint = _("按键盘 F12，点「网络」，刷新网页，复制请求标头里的整段 Cookie"),
    logout_text = _("确定退出长佩账号？"),
    loggedIn = loggedIn,
    checkAsync = function(cookie, cb)
        local Client = require("source.changpei.client")
        local previous = Client.cookie()
        return Client.userAsync(cookie, function(info, err)
            if previous ~= Client.cookie() then cb(false, _("账号已变化，请重新登录")); return end
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

--- 浏览器扩展登录（features/cookie）。getUserInfo 一律 HTTP 200，靠 JSON code 判登录（未登录 9996）。
Setting.browser = {
    domain = "www.gongzicp.com",
    scope = "cookie",
    login = "https://www.gongzicp.com/login/signin",
    check = "https://www.gongzicp.com/webapi/user/getUserInfo",
    check_json = { path = "code", ok = { 200 } },
    icon = "https://www.gongzicp.com/favicon.ico",
    isAuthorized = function() return CookieLogin.authorized(SPEC) end,
    apply = function(payload, cb) return CookieLogin.save(SPEC, CookieLogin.fromPayload(payload, "gongzicp.com"), cb) end,
}

local function startQR()
    require("ui/network/manager"):runWhenConnected(function()
        require("source.changpei.qrlogin"):new(function(cookie) CookieLogin.verify(SPEC, cookie) end):start()
    end)
end

---@return table[]
function Setting.rows()
    local rows = { CookieLogin.accountRow(SPEC, { callback = startQR }) }
    local on = loggedIn()
    if on then rows[#rows + 1] = CookieLogin.logoutRow(SPEC) end
    -- 未登录，或已保存的 Cookie 被标失效：给出换 Cookie 的入口。
    if not on or require("source.auth").expired(SOURCE_ID) then
        rows[#rows + 1] = CookieLogin.pasteRow(SPEC)
    end
    rows[#rows + 1] = function(iw)
        local ReviewSetting = require("source.review_setting")
        local enabled = ReviewSetting.enabled(SOURCE_ID)
        return require("ui.themes.widgets.row").widget({
            width = iw, kind = "toggle", icon = "forum", title = _("章节评论"),
            subtitle = _("在章末显示本章讨论，不是段落评论"), chevron = false,
            status = enabled and _("开") or _("关"), status_on = enabled,
            callback = function() ReviewSetting.set(SOURCE_ID, not enabled) end,
        })
    end
    return rows
end

--- 登录失效提示的「重新登录」：扫码和粘贴都给出来，正文里的浏览器步骤不靠这个按钮。
local function chooseLogin()
    require("ui.themes.widgets.sheet"):new{
        title = _("重新登录长佩"),
        items = {
            { text = _("用长佩 App 扫码"), callback = startQR },
            { text = _("粘贴 Cookie"), callback = function() CookieLogin.prompt(SPEC) end },
        },
    }:show()
end

Setting.login = chooseLogin

return Setting
