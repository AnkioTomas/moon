--[[--
知音漫客账号设置：短信验证码、密码与 Cookie 登录。

@module source.zymk.setting
--]]

local Login = require("source.zymk.login")
local Client = require("source.zymk.client")
local CookieLogin = require("source.cookie_login")
local _ = require("l10n").get("source.zymk")
local Setting = {}

function Setting.rowStatus()
    local on = Login.hasAccount()
    return on and _("已登录") or _("未登录 · 点此登录"), on
end

Setting.browser = {
    domain = "www.zymk.cn",
    scope = "cookie",
    login = Client.LOGIN_URL,
    check = "https://www.zymk.cn/",
    icon = "https://www.zymk.cn/static/images/default/favicon.ico",
    isAuthorized = function() return Login.hasAccount() end,
    apply = function(payload, cb)
        local cookie = CookieLogin.fromPayload(payload, "zymk.cn")
        if cookie == "" then cookie = CookieLogin.fromPayload(payload, "kanman.com") end
        if cookie == "" then return cb(false, _("没有读到 Cookie")) end
        return Login.new():cookieAsync(cookie, function(account, err)
            cb(account ~= nil, err)
        end)
    end,
}

local function onLogin()
    require("ui.themes.widgets.toast"):new{ text = _("登录成功"), timeout = 2 }:show()
end

---@param password_mode boolean
function Setting.prompt(password_mode)
    require("ui.themes.widgets.input"):new{
        title = password_mode and _("密码登录") or _("知音漫客登录 Cookie"),
        fields = password_mode and {
            { label = _("账号"), hint = _("通行证账号、手机号码或邮箱") },
            { label = _("密码"), text_type = "password" },
        } or { { hint = _("在知音漫客官网登录后，复制请求标头里的完整 Cookie") } },
        ok_text = _("登录"),
        callback = function(value, password)
            local Toast = require("ui.themes.widgets.toast")
            if not require("ui/network/manager"):isConnected() then
                Toast:new{ text = _("网络不可用，请先连接 Wi-Fi") }:show(); return
            end
            local session, cancelled = Login.new(), false
            local waiting = require("ui.themes.widgets.progress_dialog"):new{
                title = password_mode and _("密码登录") or _("知音漫客登录 Cookie"), text = _("正在校验登录…"),
                on_cancel = function() cancelled = true; session:cancel() end,
            }
            waiting:show()
            local function done(account, err)
                if cancelled then return end
                waiting:close()
                if account then onLogin()
                else Toast:new{ text = err, timeout = 3 }:show() end
            end
            if password_mode then session:passwordAsync(value, password, done)
            else session:cookieAsync(value, done) end
        end,
    }:show()
end

function Setting.rows()
    local Row = require("ui.themes.widgets.row")
    local rows = {
        function(iw)
            local status, on = Setting.rowStatus()
            return Row.widget({ width = iw, kind = "nav", title = _("短信验证码登录"),
                icon = "sms", status = status, status_on = on,
                callback = function() require("source.zymk.phone_login").new(onLogin):start() end })
        end,
        function(iw)
            return Row.widget({ width = iw, kind = "nav", title = _("密码登录"), icon = "password",
                callback = function() Setting.prompt(true) end })
        end,
        CookieLogin.browserRow(),
        function(iw)
            return Row.widget({ width = iw, kind = "nav", title = _("粘贴 Cookie"), icon = "content_paste",
                callback = function() Setting.prompt(false) end })
        end,
    }
    if require("utils.settings").getSource("zymk").account then
        rows[#rows + 1] = require("source.logout").row("zymk", _("确定退出知音漫客账号？"), function()
            local Settings = require("utils.settings")
            Settings.getSource("zymk").account = nil
            Settings.saveSource("zymk")
        end)
    end
    return rows
end

return Setting
