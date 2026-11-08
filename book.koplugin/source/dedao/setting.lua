--[[--
得到账号：手机号短信验证码、得到 App 扫码、官网浏览器登录及 Cookie 导入。

@module source.dedao.setting
--]]

require("l10n").apply()
local _ = require("gettext")
local CookieLogin = require("source.cookie_login")

local SOURCE_ID = "dedao"
local Setting = {}
local LOGIN_URL = "https://www.dedao.cn/"

---@return boolean
local function loggedIn()
    return require("source.dedao.client").loggedIn()
end

--- Cookie 请求头 → 得到 client 用的 jar。
---@param header string
---@return table<string, string>
local function jarFromHeader(header)
    local jar = {}
    for part in tostring(header):gmatch("[^;]+") do
        local name, value = part:match("^%s*([^=;%s]+)=([^%s].*)$")
        if not name then name, value = part:match("^%s*([^=;%s]+)=(.*)$") end
        if name and value and name ~= "Path" and name ~= "Domain" and name ~= "Expires"
            and name ~= "Max-Age" and name ~= "SameSite" then
            jar[name] = value
        end
    end
    return jar
end

local function save()
    local settings = require("utils.settings")
    local cfg = settings.getSource(SOURCE_ID)
    cfg.logged_in = true
    settings.saveSource(SOURCE_ID)
    require("source.auth").ok(SOURCE_ID)
    require("source.registry").reload()
    require("ui.themes.widgets.toast"):new{ text = _("登录成功"), timeout = 2 }:show()
end

function Setting.rowTitle()
    return _("得到账号")
end

---@return string, boolean
function Setting.rowStatus()
    local on = loggedIn()
    return on and _("已登录") or _("未登录 · 点此扫码"), on
end

local function qrLogin()
    require("ui/network/manager"):runWhenConnected(function()
        require("source.dedao.qrlogin"):new(save):start()
    end)
end

local function phoneLogin()
    local Text = require("utils.text")
    local Client = require("source.dedao.client")
    local Toast = require("ui.themes.widgets.toast")
    local session, pending, waiting, dialog
    local closed = false
    local function validPhone(phone)
        if #phone == 11 and phone:match("^1[3-9]%d+$") then return true end
        Toast:new{ text = _("请填写正确的手机号") }:show()
        return false
    end
    local function sendCode(phone)
        require("ui/network/manager"):runWhenConnected(function()
            if closed then return end
            if pending then pending:cancel(); pending = nil end
            if waiting then waiting:close() end
            session = nil
            local function received(value, err)
                pending = nil
                if closed then return end
                if value then session = value end
                Toast:new{ text = value and _("短信已发送，请在设备上填写验证码") or err or _("发送验证码失败") }:show()
            end
            waiting = require("ui.themes.widgets.progress_dialog"):new{
                title = _("得到账号"), text = _("正在发送短信…"),
                on_cancel = function() if pending then pending:cancel(); pending = nil end end,
            }
            waiting:show()
            local requesting = true
            local request = Client.sendCodeAsync(phone, function(value, err, challenge)
                requesting = false
                pending = nil
                waiting:close()
                waiting = nil
                if closed then return end
                if challenge then
                    local verifying = true
                    local verification = require("source.dedao.verify").new(challenge, function(result, reason)
                        verifying = false
                        received(result, reason)
                    end)
                    if verifying then pending = verification end
                    return
                end
                received(value, err)
            end)
            if requesting then pending = request end
        end)
    end
    dialog = require("ui.themes.widgets.input"):new{
        title = _("得到账号"),
        keep_open = true,
        fields = {
            { label = _("手机号"), input_type = "number" },
            { label = _("短信验证码"), input_type = "number" },
        },
        ok_text = _("登录"),
        close_callback = function()
            closed = true
            if pending then pending:cancel() end
            if waiting then waiting:close() end
        end,
        actions = { { text = _("获取验证码"), callback = function(phone)
            phone = Text.trim(phone)
            if not validPhone(phone) then return end
            require("ui.themes.widgets.confirm"):new{
                title = _("得到账号"),
                text = _("发送验证码即同意得到的用户服务协议与隐私政策，未注册手机号将自动注册。")
                    .. "\n\nhttps://zt.igetget.com/visual/1Onn4gr8OJT0QjGzq0O6.html"
                    .. "\nhttps://www.igetget.com/html/p/9MGZRxz/QlqnY8M8RzcKWG77q7Ln.html",
                ok_text = _("同意并继续"),
                ok_callback = function() sendCode(phone) end,
            }:show()
        end } },
        validate = function(phone, code)
            phone, code = Text.trim(phone), Text.trim(code)
            if not validPhone(phone) then return false end
            if not session or session.phone ~= phone then
                Toast:new{ text = _("请先获取验证码") }:show()
                return false
            end
            if code == "" or not code:match("^%d+$") then
                Toast:new{ text = _("请填写验证码") }:show()
                return false
            end
            return true
        end,
        callback = function(_phone, code)
            require("ui/network/manager"):runWhenConnected(function()
                if closed then return end
                if pending then pending:cancel(); pending = nil end
                waiting = require("ui.themes.widgets.progress_dialog"):new{
                    title = _("得到账号"), text = _("正在登录…"),
                    on_cancel = function() if pending then pending:cancel(); pending = nil end end,
                }
                waiting:show()
                local requesting = true
                local request = Client.smsLoginAsync(assert(session), Text.trim(code), function(ok, err)
                    requesting = false
                    pending = nil
                    waiting:close()
                    waiting = nil
                    if closed then return end
                    if ok then dialog:close(); save() else Toast:new{ text = err or _("登录失败") }:show() end
                end)
                if requesting then pending = request end
            end)
        end,
    }
    dialog:show()
end

function Setting.open()
    require("ui.themes.widgets.sheet"):new{
        title = _("得到账号"),
        items = {
            { text = _("手机号验证码登录"), callback = phoneLogin },
            { text = _("扫码登录"), callback = qrLogin },
        },
    }:show()
end

local SPEC = {
    id = SOURCE_ID, title = _("得到账号"), cookie_title = _("得到登录 Cookie"),
    cookie_hint = _("按键盘 F12，点「网络」，刷新网页，复制请求标头里的整段 Cookie"),
    logout_text = _("确定退出得到账号？"),
    loggedIn = loggedIn,
    checkAsync = function(cookie, cb)
        local jar = jarFromHeader(cookie)
        if not next(jar) then return cb(false, _("没有读到 Cookie")) end
        return require("source.dedao.client").confirmLoginAsync(jar, function(ok, err)
            cb(ok == true, err)
        end)
    end,
    store = function(cfg, cookie)
        cfg.cookie, cfg.logged_in = cookie, true
    end,
    clear = function(cfg)
        cfg.cookie, cfg.logged_in, cfg.uid = nil, nil, nil
        require("source.dedao.client").reset()
    end,
}

Setting.browser = {
    domain = "www.dedao.cn", scope = "cookie", login = LOGIN_URL,
    check = "https://www.dedao.cn/api/pc/user/info",
    icon = "https://www.dedao.cn/apple-touch-icon.png",
    isAuthorized = function() return CookieLogin.authorized(SPEC) end,
    apply = function(payload, cb)
        CookieLogin.save(SPEC, CookieLogin.fromPayload(payload, "dedao.cn"), cb)
    end,
}

---@return table[]
function Setting.rows()
    local Row = require("ui.themes.widgets.row")
    local rows = {
        function(iw)
            local status, status_on = Setting.rowStatus()
            return Row.widget({
                width = iw, chevron = true, kind = "nav", icon = "account_circle",
                title = Setting.rowTitle(),
                subtitle = _("手机号验证码或得到 App 扫码登录"),
                status = status, status_on = status_on,
                callback = function() Setting.open() end,
            })
        end,
        CookieLogin.browserRow(),
        CookieLogin.pasteRow(SPEC),
    }
    if loggedIn() then
        rows[#rows + 1] = CookieLogin.logoutRow(SPEC)
    end
    return rows
end

Setting.login = Setting.open

return Setting
