--[[--
书旗账号：手机验证码、官网浏览器授权和 Cookie 导入。

@module source.shuqi.setting
--]]

local _ = require("l10n").get("source.shuqi")
local CookieLogin = require("source.cookie_login")

local SOURCE_ID = "shuqi"
local Setting = {}
local LOGIN_URL = "https://t2.shuqi.com/oauth/login?priority=code&redirect_uri=https%3A%2F%2Ft.shuqi.com%2Fmyself"

---@return boolean
local function loggedIn()
    return require("source.shuqi.client").loggedIn()
end

---@param cookie string
---@param cb fun(ok: boolean, err: string|nil)
local function saveCookie(cookie, cb)
    return require("source.shuqi.client").loginCookieAsync(cookie, function(session, err)
        if session then
            require("source.auth").ok(SOURCE_ID)
            require("source.registry").reload()
        end
        cb(session ~= nil, err)
    end)
end

local function pasteCookie()
    local Toast = require("ui.themes.widgets.toast")
    if not require("ui/network/manager"):isConnected() then
        Toast:new{ text = _("网络不可用，请先连接 Wi-Fi"), timeout = 3 }:show()
        return
    end
    require("ui.themes.widgets.input"):new{
        title = _("书旗登录 Cookie"),
        fields = { { text = "", hint = _("在官网登录后，复制 t.shuqi.com 请求标头里的完整 Cookie") } },
        ok_text = _("登录"),
        callback = function(value)
            if not require("ui/network/manager"):isConnected() then
                Toast:new{ text = _("网络不可用，请先连接 Wi-Fi"), timeout = 3 }:show()
                return
            end
            local job, cancelled
            local waiting = require("ui.themes.widgets.progress_dialog"):new{
                title = _("书旗账号"), text = _("正在校验登录…"), dismissable = false,
                on_cancel = function()
                    cancelled = true
                    if job then job.cancel() end
                end,
            }
            waiting:show()
            job = saveCookie(value, function(ok, err)
                if cancelled then return end
                waiting:close()
                Toast:new{ text = ok and _("登录成功") or err, timeout = ok and 2 or 3 }:show()
            end)
        end,
    }:show()
end

Setting.browser = {
    domain = "t.shuqi.com", scope = "cookie", login = LOGIN_URL,
    check = "https://t.shuqi.com/myself",
    icon = "https://t.shuqi.com/favicon.ico",
    isAuthorized = function() return loggedIn() and not require("source.auth").expired(SOURCE_ID) end,
    apply = function(payload, cb)
        local cookies = {}
        for _idx, cookie in ipairs(type(payload.cookies) == "table" and payload.cookies or {}) do
            local host = type(cookie) == "table" and type(cookie.domain) == "string"
                and cookie.domain:gsub("^%.", ""):lower()
            if host == "shuqi.com" or host == "t.shuqi.com" then cookies[#cookies + 1] = cookie end
        end
        return saveCookie(CookieLogin.fromPayload({ cookies = cookies }, "shuqi.com"), cb)
    end,
}

local function showLogin()
    local Toast = require("ui.themes.widgets.toast")
    local function connected(run)
        if require("ui/network/manager"):isConnected() then return run() end
        Toast:new{ text = _("网络不可用，请先连接 Wi-Fi"), timeout = 3 }:show()
    end
    if not require("ui/network/manager"):isConnected() then
        Toast:new{ text = _("网络不可用，请先连接 Wi-Fi"), timeout = 3 }:show()
        return
    end
    local verification, dialog
    local agreed, closed = false, false
    local function consent(run)
        if agreed then return run() end
        require("ui.themes.widgets.confirm"):new{
            title = _("书旗账号"),
            text = _("未注册的手机号将自动注册书旗账号。继续即同意书旗用户协议和隐私政策。"),
            ok_text = _("同意并继续"),
            ok_callback = function() agreed = true; run() end,
        }:show()
    end
    local function validPhone(phone)
        if #phone == 11 and phone:match("^1%d+$") then return true end
        Toast:new{ text = _("请填写正确的手机号"), timeout = 3 }:show()
        return false
    end
    dialog = require("ui.themes.widgets.input"):new{
        title = _("书旗账号"),
        fields = {
            { label = _("手机号"), text = "", input_type = "number" },
            { label = _("验证码"), text = "", input_type = "number" },
        },
        ok_text = _("登录"),
        close_callback = function()
            closed = true
            if verification then verification:cancel() end
        end,
        actions = {
            { text = _("发送验证码"), callback = function(phone)
                phone = require("utils.text").trim(phone)
                if not validPhone(phone) then return end
                consent(function()
                    connected(function()
                        if closed then return end
                        if verification then verification:cancel() end
                        verification = require("source.shuqi.verify").new(phone, function(ok, err)
                            Toast:new{ text = ok and _("短信已发送，请在设备上填写验证码") or err, timeout = 3 }:show()
                        end)
                    end)
                end)
            end },
        },
        callback = function(phone, code)
            phone, code = require("utils.text").trim(phone), require("utils.text").trim(code)
            if not validPhone(phone) then return end
            if code == "" then
                Toast:new{ text = _("请先填写验证码"), timeout = 3 }:show()
                return
            end
            consent(function()
                connected(function()
                    local job, cancelled = nil, false
                    local waiting = require("ui.themes.widgets.progress_dialog"):new{
                        title = _("书旗账号"), text = _("正在登录…"), dismissable = false,
                        on_cancel = function()
                            cancelled = true
                            if job then job.cancel() end
                        end,
                    }
                    waiting:show()
                    local browser = verification and verification.phone == phone and verification.browser or nil
                    job = require("source.shuqi.client").loginAsync(phone, code, browser, function(session, err)
                        if cancelled then return end
                        waiting:close()
                        if not session then
                            Toast:new{ text = err or _("登录失败"), timeout = 3 }:show()
                            return
                        end
                        require("source.auth").ok(SOURCE_ID)
                        require("source.registry").reload()
                        Toast:new{ text = _("登录成功"), timeout = 2 }:show()
                    end)
                end)
            end)
        end,
    }
    dialog:show()
end

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此登录"), on
end

---@return table[]
function Setting.rows()
    local Row = require("ui.themes.widgets.row")
    local rows = {
        function(iw)
            local status, status_on = Setting.rowStatus()
            return Row.widget({
                width = iw, chevron = true, kind = "nav", icon = "account_circle",
                title = _("书旗账号"),
                subtitle = not status_on and _("滑块在同一 Wi-Fi 的浏览器里完成") or nil,
                status = status, status_on = status_on,
                callback = function() showLogin() end,
            })
        end,
        CookieLogin.browserRow(),
        function(iw)
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "content_paste",
                title = _("粘贴 Cookie"), callback = pasteCookie })
        end,
    }
    if not loggedIn() then return rows end
    rows[#rows + 1] = require("source.logout").row(SOURCE_ID, _("确定退出书旗账号？"), function()
        local settings = require("utils.settings")
        local cfg = settings.getSource(SOURCE_ID)
        cfg.token, cfg.user_id, cfg.name = nil, nil, nil
        cfg.logged_in, cfg.imei, cfg.umidtoken, cfg.wua = nil, nil, nil, nil
        settings.saveSource(SOURCE_ID)
        require("source.shuqi.client").reset()
    end)
    return rows
end

Setting.login = showLogin

return Setting
