--[[--
快看账号：微信扫码、手机号密码、短信、官网浏览器授权与 Cookie 导入。

@module source.kuaikan.setting
--]]

require("l10n").apply()
local Client = require("source.kuaikan.client")
local CookieLogin = require("source.cookie_login")
local _ = require("gettext")

local Setting = {}
local COOKIE_PATHS = { ["/"] = true, ["/v2"] = true, ["/v2/"] = true, ["/v2/pweb"] = true, ["/v2/pweb/"] = true }

function Setting.rowStatus()
    local cfg = require("utils.settings").getSource("kuaikan")
    local on = cfg.logged_in == true and type(cfg.cookie) == "string" and cfg.cookie ~= ""
        and type(cfg.user_id) == "string" and cfg.user_id ~= "" and not require("source.auth").expired("kuaikan")
    return on and _("已登录") or _("未登录 · 点此登录"), on
end

local function onLogin()
    require("source.registry").reload()
    require("ui.themes.widgets.toast"):new{ text = _("登录成功"), timeout = 2 }:show()
end

local function pasteCookie()
    local Toast = require("ui.themes.widgets.toast")
    require("ui.themes.widgets.input"):new{
        title = _("快看登录 Cookie"),
        fields = { { text = "", hint = _("在快看官网登录后，复制请求标头里的完整 Cookie") } },
        ok_text = _("登录"),
        callback = function(cookie)
            if not require("ui/network/manager"):isConnected() then
                Toast:new{ text = _("网络不可用，请先连接 Wi-Fi") }:show()
                return
            end
            local session = require("source.kuaikan.login").new()
            local cancelled = false
            local waiting = require("ui.themes.widgets.progress_dialog"):new{
                title = _("快看漫画账号"), text = _("正在校验登录…"),
                on_cancel = function() cancelled = true; session:cancel() end,
            }
            waiting:show()
            session:cookieAsync(cookie, function(account, err)
                if cancelled then return end
                waiting:close()
                if account then onLogin()
                else Toast:new{ text = err or _("登录失败"), timeout = 3 }:show() end
            end)
        end,
    }:show()
end

Setting.browser = {
    domain = "www.kuaikanmanhua.com", scope = "cookie",
    login = Client.LOGIN_URL, check = Client.ACCOUNT_URL,
    check_json = { path = "data.user_info.authenticate", ok = { 1 } },
    isAuthorized = function() local _status, on = Setting.rowStatus(); return on end,
    apply = function(payload, cb)
        local cookies = {}
        for _idx, cookie in ipairs(type(payload.cookies) == "table" and payload.cookies or {}) do
            local host = type(cookie) == "table" and type(cookie.domain) == "string"
                and cookie.domain:gsub("^%.", ""):lower()
            local path = type(cookie) == "table" and cookie.path or "/"
            if (host == "kuaikanmanhua.com" or host == "www.kuaikanmanhua.com")
                and COOKIE_PATHS[path] then
                cookies[#cookies + 1] = cookie
            end
        end
        local session = require("source.kuaikan.login").new()
        session:cookieAsync(CookieLogin.fromPayload({ cookies = cookies }, "kuaikanmanhua.com"), function(account, err)
            if account then require("source.registry").reload() end
            cb(account ~= nil, err)
        end)
        return { cancel = function() session:cancel() end }
    end,
}

function Setting.login()
    require("source.kuaikan.qrlogin").new(onLogin):start()
end

function Setting.rows()
    local Row = require("ui.themes.widgets.row")
    local rows = {
        function(iw)
            local status, on = Setting.rowStatus()
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "account_circle",
                title = _("快看漫画账号"), status = status, status_on = on,
                subtitle = _("微信扫码登录"), callback = Setting.login })
        end,
        function(iw)
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "language",
                title = _("电脑浏览器登录"), subtitle = _("账号密码和短信验证码请在官网完成"),
                callback = function()
                    require("ui.themes.widgets.text_viewer"):new{
                        title = _("电脑浏览器登录"),
                        text = _("账号密码和短信验证码请在官网完成") .. "\n\n" .. Client.LOGIN_URL .. "\n\n"
                            .. _("登录后，在远程管理的「浏览器登录」中授权快看漫画；也可回到快看账号页粘贴 Cookie。"),
                    }:show()
                end })
        end,
        function(iw)
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "content_paste",
                title = _("粘贴 Cookie"), callback = pasteCookie })
        end,
        function(iw)
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "password",
                title = _("密码登录"), callback = function()
                    require("source.kuaikan.phone_login").new("password", onLogin):start()
                end })
        end,
        function(iw)
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "sms",
                title = _("短信登录"), callback = function()
                    require("source.kuaikan.phone_login").new("sms", onLogin):start()
                end })
        end,
    }
    local cfg = require("utils.settings").getSource("kuaikan")
    if type(cfg.cookie) == "string" and cfg.cookie ~= "" then
        rows[#rows + 1] = require("source.logout").row("kuaikan", _("确定退出快看账号？"), function()
            cfg = require("utils.settings").getSource("kuaikan")
            cfg.cookie, cfg.user_id, cfg.logged_in = nil, nil, nil
            Client.login_revision = Client.login_revision + 1
            require("utils.settings").saveSource("kuaikan")
        end)
    end
    return rows
end

return Setting
