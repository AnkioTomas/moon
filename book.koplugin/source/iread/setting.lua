--[[--
iRead 源设置：登录。

两种进法：远程管理里的「浏览器登录」（浏览器扩展交网页 Cookie），或在 iread.ankio.net 创建「个人 Token」粘贴进来。
两条路都先向服务端校验，通过才保存并重载源；Token 优先于 Cookie，换一种登录会清掉另一种。

@module koplugin.book.source.iread.setting
--]]

local _ = require("l10n").get("source.iread")
local T = require("ffi/util").template

local SOURCE_ID = "iread"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.iread.client").credential() ~= nil
end

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此填写 Token"), on
end

--- 接受裸 Token，或带 `Bearer ` 前缀的整段。
---@param input string
---@return string
function Setting.parseToken(input)
    return (require("utils.text").trim(input):gsub("^[Bb]earer%s+", ""))
end

---- 保留本站和有效父域 Cookie，不收 ankio.net 下其他站点的登录态。
---@param payload table
---@return string
function Setting.fromPayload(payload)
    local cookies = {}
    for _idx, cookie in ipairs(type(payload.cookies) == "table" and payload.cookies or {}) do
        local host = type(cookie) == "table" and type(cookie.domain) == "string"
            and cookie.domain:gsub("^%.", ""):lower()
        if host == "ankio.net" or host == "iread.ankio.net" then cookies[#cookies + 1] = cookie end
    end
    return require("source.cookie_login").fromPayload({ cookies = cookies }, "ankio.net")
end

--- 校验凭据，通过才保存（Token 与 Cookie 互斥）并重载源。
---@param cred IReadCredential
---@param cb fun(user: table|nil, err: string|nil)
---@return { cancel: fun() }
function Setting.save(cred, cb)
    local client = require("source.iread.client")
    local settings = require("utils.settings")
    local cfg = settings.getSource(SOURCE_ID)
    local previous_token, previous_cookie = cfg.token, cfg.cookie
    local previous = client.credential()
    local cancelled = false
    local job = client.userAsync(cred, function(user, err)
        if cancelled then return end
        if cfg.token ~= previous_token or cfg.cookie ~= previous_cookie then
            cb(nil, _("登录状态已变化，请重试")); return
        end
        if not user then return cb(nil, err or _("登录失败")) end
        if previous and (cred.token ~= previous.token or cred.cookie ~= previous.cookie) then
            cb(nil, _("无法确认是否为同一 iRead 账号，请先退出当前账号再登录")); return
        end
        cfg.token, cfg.cookie = cred.token, cred.cookie
        settings.saveSource(SOURCE_ID, cfg)
        require("source.auth").ok(SOURCE_ID)
        require("source.registry").reload()
        cb(user)
    end)
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

--- 浏览器扩展登录（features/cookie）。
Setting.browser = {
    domain = "iread.ankio.net",
    scope = "cookie",
    login = "https://iread.ankio.net/user/token",
    check = "https://iread.ankio.net/user/token",
    icon = "https://iread.ankio.net/static/icons/favicon-32x32.png",
    isAuthorized = function()
        return loggedIn() and not require("source.auth").expired(SOURCE_ID)
    end,
    apply = function(payload, cb)
        local cookie = Setting.fromPayload(payload)
        if cookie == "" then return cb(false, _("没有读到 Cookie")) end
        return Setting.save({ cookie = cookie }, function(user, err) cb(user ~= nil, err) end)
    end,
}

---@param cred IReadCredential
local function verify(cred)
    local Toast = require("ui.themes.widgets.toast")
    require("ui/network/manager"):runWhenConnected(function()
        local job
        local waiting = require("ui.themes.widgets.progress_dialog"):new{
            title = _("iRead"), text = _("正在校验登录…"), dismissable = false,
            on_cancel = function() if job then job.cancel() end end,
        }
        waiting:show()
        job = Setting.save(cred, function(user, err)
            waiting:close()
            if not user then
                Toast:new{ text = err or _("登录失败"), timeout = 3 }:show()
                return
            end
            Toast:new{ text = T(_("已登录：%1"), user.nickname), timeout = 2 }:show()
        end)
    end)
end

local function showLogin()
    require("ui.themes.widgets.input"):new{
        title = _("iRead 个人 Token"),
        fields = { { text = "", hint = _("打开 iread.ankio.net/user/token ，新建个人 Token 后粘贴到这里") } },
        ok_text = _("登录"),
        callback = function(value)
            local token = Setting.parseToken(value or "")
            if token == "" then
                require("ui.themes.widgets.toast"):new{ text = _("没有读到 Token"), timeout = 3 }:show()
                return
            end
            verify({ token = token })
        end,
    }:show()
end

local function showCookieLogin()
    require("ui.themes.widgets.input"):new{
        title = _("iRead 登录 Cookie"),
        fields = { { text = "", hint = _("按键盘 F12，点「网络」，刷新网页，复制请求标头里的整段 Cookie") } },
        ok_text = _("登录"),
        callback = function(value)
            local cookie = require("source.cookie_login").parse(value or "")
            if cookie == "" then
                require("ui.themes.widgets.toast"):new{ text = _("没有读到 Cookie"), timeout = 3 }:show()
                return
            end
            verify({ cookie = cookie })
        end,
    }:show()
end

---@return table[]
function Setting.rows()
    local Row = require("ui.themes.widgets.row")
    local CookieLogin = require("source.cookie_login")
    local rows = {
        function(iw)
            local status, status_on = Setting.rowStatus()
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "account_circle",
                title = _("iRead 账号"), status = status, status_on = status_on,
                callback = function() showLogin() end })
        end,
        CookieLogin.browserRow(),
        function(iw)
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "content_paste",
                title = _("粘贴 Cookie"), callback = showCookieLogin })
        end,
    }
    if not loggedIn() then return rows end
    rows[#rows + 1] = require("source.logout").row(SOURCE_ID, _("确定退出 iRead 账号？"), function()
        local settings = require("utils.settings")
        local cfg = settings.getSource(SOURCE_ID)
        cfg.token, cfg.cookie = nil, nil
        settings.saveSource(SOURCE_ID, cfg)
    end)
    return rows
end

--- 登录失效提示的「重新登录」直达入口（desktop.sync.promptLogin）。
Setting.login = showLogin

return Setting
