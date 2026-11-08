--[[--
快看手机号密码与短信登录。输入窗、滑块和 HTTP 共用本次候选会话。

@module source.kuaikan.phone_login
--]]

local Mapper = require("source.kuaikan.mapper")
local Text = require("utils.text")
local _ = require("l10n").get("source.kuaikan")

---@class KuaikanPhoneLogin
---@field mode string
---@field session KuaikanLogin
---@field generation integer
---@field busy boolean|nil
---@field agreed boolean|nil
---@field verification KuaikanVerification|nil
---@field dialog BookThemeInput|nil
---@field on_user fun(account: table)
local PhoneLogin = {}
PhoneLogin.__index = PhoneLogin

function PhoneLogin.new(mode, on_user)
    return setmetatable({
        mode = mode, on_user = on_user, generation = 0,
        session = require("source.kuaikan.login").new(),
    }, PhoneLogin)
end

function PhoneLogin:cancel()
    self.generation = self.generation + 1
    if self.verification then self.verification:cancel(); self.verification = nil end
    self.session:cancel()
    self.busy, self.dialog = false, nil
end

function PhoneLogin:ready(country, number)
    local err
    if self.busy then err = _("正在处理，请稍候")
    elseif not require("ui/network/manager"):isConnected() then err = _("网络不可用，请先连接 Wi-Fi") end
    local phone = Mapper.phone(country, number)
    if not err and not phone then err = _("请输入有效的手机号和国际区号") end
    if err then require("ui.themes.widgets.toast"):new{ text = err }:show(); return nil end
    return phone
end

function PhoneLogin:agree(fn)
    if self.agreed then fn(); return end
    local gen = self.generation
    require("ui.themes.widgets.confirm"):new{
        text = _("登录前请阅读并同意快看用户协议和隐私协议")
            .. "\nhttps://www.kuaikanmanhua.com/webs/agreement"
            .. "\nhttps://h5.kuaikanmanhua.com/normal/protocol/?type=1"
            .. "\nhttps://h5.kuaikanmanhua.com/normal/protocol/?type=2",
        ok_text = _("同意并继续"),
        ok_callback = function()
            if gen ~= self.generation then return end
            self.agreed = true
            fn()
        end,
    }:show()
end

function PhoneLogin:captcha(country, number, password)
    local phone = self:ready(country, number)
    if not phone then return end
    if self.mode == "password" and password == "" then
        require("ui.themes.widgets.toast"):new{ text = _("请输入密码") }:show()
        return
    end
    if self.mode ~= "password" and self.session.sms_retry_at and os.time() < self.session.sms_retry_at then
        require("ui.themes.widgets.toast"):new{ text = _("请稍后再获取验证码") }:show()
        return
    end
    self:agree(function()
        if not self:ready(country, number) then return end
        self.busy = true
        local dialog = self.dialog
        self.dialog = nil
        dialog:close()
        local gen = self.generation
        local verification = require("source.kuaikan.verify").new(self.session, function(proof, cb)
            if self.mode == "password" then self.session:passwordAsync(phone, password, proof, cb)
            else self.session:sendCodeAsync(phone, proof, cb) end
        end, function(result, err)
            if gen ~= self.generation then return end
            self.busy, self.verification = false, nil
            if result and self.mode == "password" then
                self:cancel()
                self.on_user(result)
                return
            end
            self:start(country, number)
            require("ui.themes.widgets.toast"):new{
                text = result and _("验证码已发送") or err or _("登录失败"), timeout = 4,
            }:show()
        end)
        if not verification.done then self.verification = verification end
    end)
end

function PhoneLogin:verify(country, number, code)
    local phone = self:ready(country, number)
    if not phone then return end
    code = Text.trim(code)
    if phone ~= self.session.sms_phone or not code:match("^%d+$") then
        require("ui.themes.widgets.toast"):new{
            text = _("请先获取该手机号的验证码，再填写验证码登录"),
        }:show()
        return
    end
    self.busy = true
    local gen = self.generation
    self.session:codeAsync(phone, code, function(account, err)
        if gen ~= self.generation then return end
        self.busy = false
        if not account then require("ui.themes.widgets.toast"):new{ text = err or _("登录失败") }:show(); return end
        self.dialog:close()
        self:cancel()
        self.on_user(account)
    end)
end

function PhoneLogin:start(country, number)
    local password = self.mode == "password"
    local dialog
    dialog = require("ui.themes.widgets.input"):new{
        title = password and _("快看密码登录") or _("快看短信登录"),
        fields = {
            { label = _("国际区号"), text = country or "+86" },
            { label = _("手机号"), text = number or "", input_type = "number" },
            { label = password and _("密码") or _("验证码"),
                text_type = password and "password" or nil, input_type = not password and "number" or nil },
        },
        keep_open = true, ok_text = _("登录"),
        actions = not password and { { text = _("获取验证码"), callback = function(cc, phone)
            if self.dialog == dialog then self:captcha(cc, phone) end
        end } } or nil,
        callback = function(cc, phone, value)
            if self.dialog ~= dialog then return end
            if password then self:captcha(cc, phone, value) else self:verify(cc, phone, value) end
        end,
        close_callback = function() if self.dialog == dialog then self:cancel() end end,
    }
    self.dialog = dialog
    dialog:show()
end

return PhoneLogin
