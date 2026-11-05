--[[--
七猫源设置：登录。

手机号与短信验证码在设备上填写，发送短信前的数美滑块经远程管理桥接。
登录态仍是网页 token（`Authorization`）；保留原来的 token 导入，保存前向服务端校验。

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
    require("ui/network/manager"):runWhenConnected(function()
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

local function showTokenLogin()
    require("ui.themes.widgets.input"):new{
        title = _("七猫登录 token"),
        fields = { { text = "", hint = _("按 F12，点「应用」里的本地存储，复制 ls_qimao_global_userinfo_data 中的 token") } },
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

local function showLogin()
    local Toast = require("ui.themes.widgets.toast")
    local verification, dialog
    local agreed, closed = false, false
    local function consent(run)
        if agreed then return run() end
        require("ui.themes.widgets.confirm"):new{
            title = _("七猫账号"),
            text = _("未注册的手机号将自动注册七猫账号。继续即同意七猫用户协议和隐私政策。")
                .. "\nhttps://www.qimao.com/user_agreed.html\nhttps://www.qimao.com/privacy_agreed.html",
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
        title = _("七猫账号"),
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
                    require("ui/network/manager"):runWhenConnected(function()
                        if closed then return end
                        if verification then verification:cancel() end
                        verification = require("source.qimao.verify").new(phone, function(ok, err)
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
                require("ui/network/manager"):runWhenConnected(function()
                    local waiting = require("ui.themes.widgets.progress_dialog"):new{
                        title = _("七猫账号"), text = _("正在登录…"), dismissable = false,
                    }
                    waiting:show()
                    require("source.qimao.client").loginAsync(phone, code, function(token, err)
                        if not token then
                            waiting:close()
                            Toast:new{ text = err, timeout = 3 }:show()
                            return
                        end
                        saveToken(token, function(ok, message)
                            waiting:close()
                            Toast:new{ text = ok and _("登录成功") or message, timeout = ok and 2 or 3 }:show()
                        end)
                    end)
                end)
            end)
        end,
    }
    dialog:show()
end

---@return table[]
function Setting.rows()
    local Row = require("ui.themes.widgets.row")
    local rows = {
        function(iw)
            local status, status_on = Setting.rowStatus()
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "account_circle",
                title = _("七猫账号"), status = status, status_on = status_on,
                subtitle = not status_on and _("也可在「远程管理」里用浏览器授权登录") or nil,
                callback = function() showLogin() end })
        end,
        function(iw)
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "key",
                title = _("用 token 登录"), callback = showTokenLogin })
        end,
    }
    if not loggedIn() then return rows end
    rows[#rows + 1] = require("source.logout").row(SOURCE_ID, _("确定退出七猫账号？"), function()
        local settings = require("utils.settings")
        local cfg = settings.getSource(SOURCE_ID)
        cfg.token = nil
        settings.saveSource(SOURCE_ID, cfg)
    end)
    return rows
end

--- 登录失效提示的「重新登录」直达入口（desktop.sync.promptLogin）。
Setting.login = showLogin

return Setting
