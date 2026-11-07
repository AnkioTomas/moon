--[[--
豆瓣阅读短信登录。手机号、验证码和候选会话只属于当前输入窗口。

@module source.douban.phone_login
--]]

require("l10n").apply()
local Client = require("source.douban.client")
local Text = require("utils.text")
local _ = require("gettext")

local PhoneLogin = {}
PhoneLogin.__index = PhoneLogin

function PhoneLogin:new(on_user)
    return setmetatable({ on_user = on_user, session = Client.newLogin(), generation = 0 }, PhoneLogin)
end

function PhoneLogin:cancel()
    self.generation = self.generation + 1
    if self.job then self.job.cancel() end
    self.job, self.busy = nil, false
    self.session:cancel()
end

function PhoneLogin:_request(method, callback, ...)
    local args = { ... }
    local count, pending, gen = select("#", ...) + 1, true, self.generation
    self.busy = true
    args[count] = function(...)
        pending = false
        if gen ~= self.generation then return end
        self.job, self.busy = nil, false
        callback(...)
    end
    local job = self.session[method](self.session, unpack(args, 1, count))
    if pending then self.job = job end
end

function PhoneLogin:send(country, number)
    if not require("ui/network/manager"):isConnected() then
        require("ui.themes.widgets.toast"):new{ text = _("网络不可用，请先连接 Wi-Fi"), timeout = 3 }:show()
        return
    end
    if self.busy then
        require("ui.themes.widgets.toast"):new{ text = _("正在处理，请稍候"), timeout = 2 }:show()
        return
    end
    country, number = Text.trim(country), Text.trim(number)
    if not country:match("^%+%d+$") or not number:match("^%d+$") then
        require("ui.themes.widgets.toast"):new{ text = _("请输入有效的手机号和国际区号"), timeout = 3 }:show()
        return
    end
    local phone = country .. number
    if self.retry_at and os.time() < self.retry_at then
        require("ui.themes.widgets.toast"):new{ text = _("请稍后再获取验证码"), timeout = 3 }:show()
        return
    end
    if not self.session.authorize then
        require("ui.themes.widgets.toast"):new{ text = _("正在获取验证码…"), timeout = 2 }:show()
        self:_request("beginAsync", function(authorize, err)
            if not authorize then
                require("ui.themes.widgets.toast"):new{ text = err or _("登录失败"), timeout = 3 }:show()
                return
            end
            self:send(country, number)
        end)
        return
    end
    self:_request("sendPhoneCodeAsync", function(wait, err)
        if wait == nil then
            require("ui.themes.widgets.toast"):new{ text = err or _("请求失败"), timeout = 3 }:show()
            return
        end
        self.phone, self.retry_at = phone, os.time() + wait
        require("ui.themes.widgets.toast"):new{ text = _("验证码已发送"), timeout = 3 }:show()
    end, phone)
end

function PhoneLogin:verify(country, number, code)
    if self.busy then
        require("ui.themes.widgets.toast"):new{ text = _("正在处理，请稍候"), timeout = 2 }:show()
        return
    end
    if not require("ui/network/manager"):isConnected() then
        require("ui.themes.widgets.toast"):new{ text = _("网络不可用，请先连接 Wi-Fi"), timeout = 3 }:show()
        return
    end
    local phone = Text.trim(country) .. Text.trim(number)
    code = Text.trim(code)
    if phone ~= self.phone or not code:match("^%d+$") then
        require("ui.themes.widgets.toast"):new{ text = _("请先获取该手机号的验证码，再填写验证码登录"), timeout = 3 }:show()
        return
    end
    require("ui.themes.widgets.toast"):new{ text = _("正在登录…"), timeout = 2 }:show()
    self:_request("verifyPhoneAsync", function(user, err)
        if not user then
            require("ui.themes.widgets.toast"):new{ text = err or _("登录失败"), timeout = 4 }:show()
            return
        end
        self:cancel()
        self.dialog:close()
        self.on_user(user)
    end, phone, code)
end

function PhoneLogin:start()
    self.dialog = require("ui.themes.widgets.input"):new{
        title = _("豆瓣阅读手机号登录"),
        fields = {
            { label = _("国际区号"), text = "+86", hint = "+86" },
            { label = _("手机号"), input_type = "number" },
            { label = _("验证码"), input_type = "number" },
        },
        keep_open = true,
        ok_text = _("登录"),
        actions = { { text = _("获取验证码"), callback = function(country, number) self:send(country, number) end } },
        callback = function(country, number, code)
            require("ui.themes.widgets.confirm"):new{
                text = _("登录前请阅读并同意豆瓣阅读使用协议、隐私政策和社区指导原则")
                    .. "\nhttps://read.douban.com/about/agreement\nhttps://read.douban.com/privacy"
                    .. "\nhttps://read.douban.com/faq?type=guideline",
                ok_text = _("同意并登录"),
                ok_callback = function() self:verify(country, number, code) end,
            }:show()
        end,
        cancel_callback = function() self:cancel() end,
    }
    self.dialog:show()
end

return PhoneLogin
