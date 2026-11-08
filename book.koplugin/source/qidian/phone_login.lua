--[[--
起点手机号短信登录窗口。取消只终止本窗口的候选会话，不影响已保存账号。

@module source.qidian.phone_login
--]]

local Text = require("utils.text")
local _ = require("l10n").get("source.qidian")
---@class QidianPhoneLogin
---@field session QidianLogin
---@field on_cookie fun(cookie: string)
---@field dialog BookThemeInput
---@field verification QidianVerification|nil
---@field phone string|nil
---@field retry_at integer|nil
---@field agreed boolean|nil
---@field busy boolean|nil
---@field closed boolean|nil
local PhoneLogin = {}
PhoneLogin.__index = PhoneLogin

function PhoneLogin.new(on_cookie)
    return setmetatable({ session = require("source.qidian.login").new(), on_cookie = on_cookie }, PhoneLogin)
end

function PhoneLogin:cancel()
    self.closed, self.busy = true, false
    if self.verification then self.verification:cancel() end
    self.session:cancel()
    self.phone = nil
end

function PhoneLogin:toast(message)
    require("ui.themes.widgets.toast"):new{ text = message, timeout = 3 }:show()
end

function PhoneLogin:available()
    if self.closed then return false end
    if self.busy then self:toast(_("正在处理，请稍候")); return false end
    if not require("ui/network/manager"):isConnected() then
        self:toast(_("网络不可用，请先连接 Wi-Fi")); return false
    end
    return true
end

function PhoneLogin:_send(country, phone, proof)
    self.busy = true
    self.session:sendCodeAsync(country, phone, proof, function(data, err) self:_sent(country, phone, data, err) end)
end

function PhoneLogin:_sent(country, phone, data, err)
    if self.closed then return end
    self.busy = false
    if not data then self:toast(err or _("请求失败")); return end
    if tonumber(data.nextAction) == 0 then
        self.phone, self.retry_at = country .. phone, os.time() + 60
        self:toast(_("验证码已发送")); return
    end
    self.busy = true
    local verification = require("source.qidian.verify").new(self.session, data, function(proof, done)
        self.session:sendCodeAsync(country, phone, proof, done)
    end, function(result, reason)
        self.verification = nil
        self:_sent(country, phone, result, reason)
    end)
    if not verification.done then self.verification = verification end
end

function PhoneLogin:send(country, phone)
    if not self:available() then return end
    country, phone = Text.trim(country), Text.trim(phone)
    if not country:match("^%+%d+$") or #country > 5 or not phone:match("^%d+$") or #phone < 6 or #phone > 15 then
        self:toast(_("请输入有效的手机号和国际区号")); return
    end
    if self.retry_at and os.time() < self.retry_at then self:toast(_("请稍后再获取验证码")); return end
    if not self.agreed then
        require("ui.themes.widgets.confirm"):new{
            text = _("获取验证码前请阅读并同意阅文用户服务协议和隐私政策")
                .. "\nhttps://passport.yuewen.com/terms_of_service.html"
                .. "\nhttps://passport.yuewen.com/privacy_policy.html",
            ok_text = _("同意并获取验证码"),
            ok_callback = function() self.agreed = true; self:send(country, phone) end,
        }:show()
        return
    end
    self:toast(_("正在获取验证码…"))
    if self.session.initialized then self:_send(country, phone); return end
    self.busy = true
    self.session:beginAsync(function(data, err)
        if self.closed then return end
        self.busy = false
        if not data then self:toast(err or _("登录失败")); return end
        self:_send(country, phone)
    end)
end

function PhoneLogin:verify(country, phone, code)
    if not self:available() then return end
    country, phone, code = Text.trim(country), Text.trim(phone), Text.trim(code)
    if country .. phone ~= self.phone or not code:match("^%d+$") then
        self:toast(_("请先获取该手机号的验证码，再填写验证码登录")); return
    end
    self.busy = true
    self:toast(_("正在登录…"))
    self.session:verifyAsync(phone, code, function(cookie, err)
        if self.closed then return end
        self.busy = false
        if not cookie then self:toast(err or _("登录失败")); return end
        self:cancel()
        self.dialog:close()
        self.on_cookie(cookie)
    end)
end

function PhoneLogin:start()
    self.dialog = require("ui.themes.widgets.input"):new{
        title = _("起点手机号验证码登录"),
        fields = {
            { label = _("国际区号"), text = "+86", hint = "+86" },
            { label = _("手机号"), input_type = "number" },
            { label = _("验证码"), input_type = "number" },
        },
        keep_open = true, ok_text = _("登录"),
        actions = { { text = _("获取验证码"), callback = function(country, phone) self:send(country, phone) end } },
        callback = function(country, phone, code) self:verify(country, phone, code) end,
        cancel_callback = function() self:cancel() end,
    }
    self.dialog:show()
end

return PhoneLogin
