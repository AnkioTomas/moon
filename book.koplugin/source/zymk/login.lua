--[[--
知音漫客短信验证码、密码与 Cookie 登录会话。密码不落盘，appToken 只用于兑换；
服务端校验成功才保存 type/openid。公开阅读仍可匿名使用。

@module source.zymk.login
--]]

local Client = require("source.zymk.client")
local Mapper = require("source.zymk.mapper")
local Settings = require("utils.settings")
local JSON = require("json")
local Text = require("utils.text")
local _ = require("l10n").get("source.zymk")

---@class ZymkLogin
---@field previous ZymkAccount|nil
---@field serial integer
---@field job HttpJob|nil
---@field sms_phone string|nil
---@field retry_at number|nil
---@field captcha ZymkCaptcha|nil
local Login = {}
Login.__index = Login

function Login.new()
    return setmetatable({ previous = Settings.getSource("zymk").account, serial = 0 }, Login)
end

function Login.hasAccount()
    return Mapper.account(Settings.getSource("zymk").account) ~= nil
        and not require("source.auth").expired("zymk")
end

function Login:cancel()
    self.serial = self.serial + 1
    if self.job then self.job.cancel(); self.job = nil end
end

---@param path string
---@param fields table
---@param cb fun(data: table|nil, err: string|nil)
function Login:request(path, fields, cb)
    self:cancel()
    local serial, pending = self.serial, true
    local function done(data, err)
        pending = false
        if self.serial ~= serial then return end
        self.job = nil
        if Settings.getSource("zymk").account ~= self.previous then
            cb(nil, _("登录状态已变化，请重试")); return
        end
        cb(data, err and tostring(err) or nil)
    end
    local job = Client.authAsync(path, fields, done)
    if pending then self.job = job end
end

---@param fields table
---@param cb fun(account: ZymkAccount|nil, err: string|nil)
function Login:confirm(fields, cb)
    self:request("/apinew/getuserinfo/", fields, function(data, err)
        if not data then cb(nil, err); return end
        local account = Mapper.account(data)
        if not account then cb(nil, _("登录响应无效")); return end
        if fields.openid and (account.openid ~= fields.openid or account.type ~= fields.type) then
            cb(nil, _("登录响应无效")); return
        end
        if self.previous and (self.previous.openid ~= account.openid or self.previous.type ~= account.type) then
            cb(nil, _("请先退出旧知音漫客账号，再登录其他账号")); return
        end
        Settings.getSource("zymk").account = account
        Settings.saveSource("zymk")
        require("source.auth").ok("zymk")
        require("source.registry").reload()
        cb(account)
    end)
end

---@param phone string
---@param points table[]|nil 用户点选的原图坐标
---@param refresh boolean
---@param cb fun(data: table|nil, err: string|nil)
function Login:sendSmsAsync(phone, points, refresh, cb)
    if not phone:match("^1%d%d%d%d%d%d%d%d%d%d$") then cb(nil, _("请输入正确的手机号")); return end
    if self.retry_at and os.time() < self.retry_at then cb(nil, _("请稍后再获取验证码")); return end
    local img_code = ""
    if points then
        if not self.captcha or #points ~= 2 then cb(nil, _("请重新获取图形验证码")); return end
        for _index, point in ipairs(points) do
            if type(point.x) ~= "number" or type(point.y) ~= "number"
                or point.x < 0 or point.x >= self.captcha.width
                or point.y < 0 or point.y >= self.captcha.height then
                cb(nil, _("请重新获取图形验证码")); return
            end
        end
        img_code = JSON.encode({ appId = 11, fontPoints = points, userIdentifier = phone, verificaType = 2 })
    end
    self.captcha = nil
    self:request("/apinew/sendsms/", {
        mobile = phone, service = "zymk", imgCode = img_code, refresh = refresh and 1 or 0,
    }, function(data, err)
        if data and data.sent then self.sms_phone, self.retry_at = phone, os.time() + 60
        elseif data then self.captcha = data end
        cb(data, err)
    end)
end

---@param phone string
---@param code string
---@param cb fun(account: ZymkAccount|nil, err: string|nil)
function Login:codeAsync(phone, code, cb)
    if phone ~= self.sms_phone or not code:match("^%d+$") then
        cb(nil, _("请先获取该手机号的验证码，再填写验证码登录")); return
    end
    self:request("/apinew/mobilevclogin/", { mobile = phone, vcode = code }, function(data, err)
        if not data then cb(nil, err); return end
        if type(data.appToken) ~= "string" or data.appToken == "" then
            cb(nil, _("登录响应无效")); return
        end
        self:confirm({ type = "mkxq", token = data.appToken }, cb)
    end)
end

---@param identity string
---@param password string
---@param cb fun(account: ZymkAccount|nil, err: string|nil)
function Login:passwordAsync(identity, password, cb)
    if identity == "" or password == "" then cb(nil, _("请输入账号和密码")); return end
    self:request("/userapi/login/", { identity = identity, pwd = password }, function(data, err)
        if not data then cb(nil, err); return end
        if type(data.appToken) ~= "string" or data.appToken == "" then
            cb(nil, _("登录响应无效")); return
        end
        self:confirm({ type = "mkxq", token = data.appToken }, cb)
    end)
end

---@param cookie string
---@param cb fun(account: ZymkAccount|nil, err: string|nil)
function Login:cookieAsync(cookie, cb)
    local header = require("source.cookie_login").parse(cookie)
    local value = header:match("^user=([^;]+)") or header:match("; user=([^;]+)")
    if not value then cb(nil, _("没有读到知音漫客登录 Cookie")); return end
    local decoded, data = pcall(JSON.decode, Text.urlDecode(value))
    local account = decoded and Mapper.account(data)
    if not account then cb(nil, _("没有读到知音漫客登录 Cookie")); return end
    self:confirm(account, cb)
end

return Login
