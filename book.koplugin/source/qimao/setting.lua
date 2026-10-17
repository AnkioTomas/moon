--[[--
七猫源设置：登录。

七猫网页登录的短信验证码要先过数美滑块，墨水屏上做不了；登录态就是网页的 token（每个请求的
`Authorization`），在电脑浏览器登录七猫后复制 token 粘贴进来即可，粘贴时会先向服务端校验。

@module koplugin.book.source.qimao.setting
--]]

require("l10n").apply()
local _ = require("gettext")

local SOURCE_ID = "qimao"
local Setting = {}

---@return boolean
local function loggedIn()
    return require("source.qimao.client").token() ~= nil
end

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此登录"), on
end

--- 接受裸 token，或浏览器 localStorage `ls_qimao_global_userinfo_data` 的整段 JSON。
---@param input string
---@return string
function Setting.parseToken(input)
    local text = require("utils.text").trim(input)
    if text:sub(1, 1) == "{" then
        local ok, data = pcall(require("json").decode, text)
        return ok and type(data) == "table" and type(data.token) == "string" and data.token or ""
    end
    return (text:gsub("^[Bb]earer%s+", ""))
end

--- 向服务端校验 token，通过才保存并重载源。
---@param token string
---@param cb fun(ok: boolean, err: string|nil)
local function saveToken(token, cb)
    require("source.qimao.client").userInfoAsync(token, function(user, err)
        if not user then return cb(false, err or _("登录失败")) end
        local settings = require("utils.settings")
        local cfg = settings.getSource(SOURCE_ID)
        cfg.token = token
        settings.saveSource(SOURCE_ID, cfg)
        require("source.auth").ok(SOURCE_ID)
        require("source.registry").reload()
        cb(true)
    end)
end

---@param token string
local function verify(token)
    local Toast = require("ui.themes.widgets.toast")
    require("ui/network/manager"):runWhenOnline(function()
        local waiting = require("ui.themes.widgets.progress_dialog"):new{
            title = _("七猫账号"), text = _("正在校验登录…"), dismissable = false,
        }
        waiting:show()
        saveToken(token, function(ok, err)
            waiting:close()
            Toast:new{ text = ok and _("登录成功") or err, timeout = ok and 2 or 3 }:show()
        end)
    end)
end

--- 浏览器扩展登录（features/cookie）：登录态在 localStorage 的用户信息里。
Setting.browser = {
    domain = "www.qimao.com",
    scope = "local",
    login = "https://www.qimao.com/login",
    check = "https://www.qimao.com/user/bookshelf",
    icon = "https://cdn-front.qimao.com/global/static/images/favicon2022.ico",
    isAuthorized = function()
        return loggedIn() and not require("source.auth").expired(SOURCE_ID)
    end,
    apply = function(payload, cb)
        local storage = payload["local"]
        local raw = type(storage) == "table" and storage.ls_qimao_global_userinfo_data
        local token = type(raw) == "string" and Setting.parseToken(raw) or ""
        if token == "" then return cb(false, _("没有读到 token")) end
        saveToken(token, cb)
    end,
}

local function showLogin()
    require("ui.themes.widgets.input"):new{
        title = _("七猫登录 token"),
        fields = { { text = "", hint = _("在电脑浏览器登录七猫后粘贴 token") } },
        ok_text = _("登录"),
        callback = function(value)
            local token = Setting.parseToken(value or "")
            if token == "" then
                require("ui.themes.widgets.toast"):new{ text = _("没有读到 token"), timeout = 3 }:show()
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
                title = _("七猫账号"), status = status, status_on = status_on,
                callback = function() showLogin() end })
        end,
    }
    if not loggedIn() then return rows end
    rows[#rows + 1] = function(iw)
        return Row.widget({ width = iw, chevron = false, kind = "action", icon = "logout", title = _("退出登录"),
            callback = function()
                require("ui.themes.widgets.confirm"):new{
                    text = _("确定退出七猫账号？"),
                    ok_text = _("退出登录"),
                    ok_callback = function()
                        local settings = require("utils.settings")
                        local cfg = settings.getSource(SOURCE_ID)
                        cfg.token = nil
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
