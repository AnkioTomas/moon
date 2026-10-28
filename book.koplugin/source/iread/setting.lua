--[[--
iRead 源设置：登录。

两种进法：远程管理里的「浏览器登录」（浏览器扩展交网页 Cookie），或在 iread.ankio.net 创建「个人 Token」粘贴进来。
两条路都先向服务端校验，通过才保存并重载源；Token 优先于 Cookie，换一种登录会清掉另一种。

@module koplugin.book.source.iread.setting
--]]

require("l10n").apply()
local _ = require("gettext")
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

--- 浏览器扩展交来的 payload.cookies → Cookie 请求头；只收发往 ankio.net 及其子域的 Cookie。
---@param payload table
---@return string
function Setting.fromPayload(payload)
    return require("source.cookie_login").fromPayload(payload, "ankio.net")
end

--- 校验凭据，通过才保存（Token 与 Cookie 互斥）并重载源。
---@param cred IReadCredential
---@param cb fun(user: table|nil, err: string|nil)
local function save(cred, cb)
    require("source.iread.client").userAsync(cred, function(user, err)
        if not user then return cb(nil, err or _("登录失败")) end
        local settings = require("utils.settings")
        local cfg = settings.getSource(SOURCE_ID)
        cfg.token, cfg.cookie = cred.token, cred.cookie
        settings.saveSource(SOURCE_ID, cfg)
        require("source.auth").ok(SOURCE_ID)
        require("source.registry").reload()
        cb(user)
    end)
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
        save({ cookie = cookie }, function(user, err) cb(user ~= nil, err) end)
    end,
}

---@param token string
local function verify(token)
    local Toast = require("ui.themes.widgets.toast")
    require("ui/network/manager"):runWhenConnected(function()
        local waiting = require("ui.themes.widgets.progress_dialog"):new{
            title = _("iRead"), text = _("正在校验 Token…"), dismissable = false,
        }
        waiting:show()
        save({ token = token }, function(user, err)
            waiting:close()
            if not user then
                Toast:new{ text = err or _("Token 无效"), timeout = 3 }:show()
                return
            end
            Toast:new{ text = T(_("已登录：%1"), user.nickname), timeout = 2 }:show()
        end)
    end)
end

local function showLogin()
    require("ui.themes.widgets.input"):new{
        title = _("iRead 个人 Token"),
        fields = { { text = "", hint = _("在 iread.ankio.net 的个人 Token 页创建后粘贴") } },
        ok_text = _("登录"),
        callback = function(value)
            local token = Setting.parseToken(value or "")
            if token == "" then
                require("ui.themes.widgets.toast"):new{ text = _("没有读到 Token"), timeout = 3 }:show()
                return
            end
            verify(token)
        end,
    }:show()
end

---@return table[]
function Setting.rows()
    local Row = require("ui.themes.widgets.row")
    local rows = {
        function(iw)
            local status, status_on = Setting.rowStatus()
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "account_circle",
                title = _("iRead 账号"), status = status, status_on = status_on,
                subtitle = not status_on and _("也可在「远程管理」里用浏览器授权登录") or nil,
                callback = function() showLogin() end })
        end,
    }
    if not loggedIn() then return rows end
    rows[#rows + 1] = function(iw)
        return Row.widget({ width = iw, chevron = false, kind = "action", icon = "logout", title = _("退出登录"),
            callback = function()
                require("ui.themes.widgets.confirm"):new{
                    text = _("确定退出 iRead 账号？"),
                    ok_text = _("退出登录"),
                    ok_callback = function()
                        local settings = require("utils.settings")
                        local cfg = settings.getSource(SOURCE_ID)
                        cfg.token, cfg.cookie = nil, nil
                        settings.saveSource(SOURCE_ID, cfg)
                        require("ui.themes.widgets.toast"):new{ text = _("已退出登录"), timeout = 2 }:show()
                        require("source.registry").reload()
                    end,
                }:show()
            end })
    end
    return rows
end

--- 登录失效提示的「重新登录」直达入口（desktop.sync.promptLogin）。
Setting.login = showLogin

return Setting
