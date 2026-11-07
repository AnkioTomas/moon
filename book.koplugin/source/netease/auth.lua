--[[--
电脑端登录会话。Cookie 归本次登录窗口所有，校验成功才替换持久会话。
密码响应是 HTML 中的 mobileCallback，不是手机版 JSON。

@module source.netease.auth
--]]

require("l10n").apply()
local Request = require("http.request")
local Text = require("utils.text")
local Mapper = require("source.netease.mapper")
local _ = require("gettext")

local ORIGIN = "https://yuedu.163.com"
local CALLBACK = ORIGIN .. "/weiboCallback.do?site=7&from=login&fromHttps=true"

---@class NeteaseLogin
---@field cookies table<string, string>
---@field job HttpJob|nil
---@field serial integer
---@field prepared boolean|nil
local Login = {}
Login.__index = Login

function Login.new()
    return setmetatable({ cookies = {}, serial = 0 }, Login)
end

function Login:cancel()
    self.serial = self.serial + 1
    if self.job then self.job:cancel(); self.job = nil end
end

function Login:cookie()
    local names, parts = {}, {}
    for name in pairs(self.cookies) do names[#names + 1] = name end
    table.sort(names)
    for _idx, name in ipairs(names) do parts[#parts + 1] = name .. "=" .. self.cookies[name] end
    return table.concat(parts, "; ")
end

--- 同步回调不能把后续请求的取消句柄覆盖掉；微信请求不携带网易 Cookie。
function Login:request(method, url, fields, cb)
    self.serial = self.serial + 1
    local serial, pending = self.serial, true
    local options = { timeout = require("http.timeout").net(1.5) }
    if url:sub(1, #ORIGIN + 1) == ORIGIN .. "/" then
        options.headers = { Cookie = self:cookie(), Referer = ORIGIN .. "/loginForm.do" }
    end
    local function done(raw, err, res)
        pending = false
        if serial ~= self.serial then return end
        self.job = nil
        if options.headers then
            for _idx, line in ipairs(Request.headerAll(res, "Set-Cookie")) do
                local name, value = line:match("^%s*([^=;%s]+)=([^;]*)")
                if name then
                    self.cookies[name] = value ~= "" and value ~= '""' and value or nil
                end
            end
        end
        cb(raw, err, res)
    end
    local job
    if method == "POST" then
        job = Request.post(url, Text.formEncode(fields), options, done)
    else
        job = Request.get(url, options, done)
    end
    if pending and serial == self.serial then self.job = job end
end

function Login:confirm(cb)
    self:request("GET", ORIGIN .. "/myinfor.do", nil, function(raw, err)
        if not Mapper.authorized(raw) then
            cb(nil, err and tostring(err) or _("网易云阅读登录校验失败，请在浏览器重新登录"))
            return
        end
        local settings = require("utils.settings")
        local cfg = settings.getSource("netease")
        cfg.cookie, cfg.logged_in, cfg.csrf = self:cookie(), true, nil
        settings.saveSource("netease")
        require("source.auth").ok("netease")
        cb(true)
    end)
end

function Login:prepare(cb)
    if self.prepared then cb(true); return end
    self:request("GET", ORIGIN .. "/loginForm.do?targetUrl=" .. Text.urlEncode(ORIGIN .. "/myinfor.do"),
        nil, function(raw, err)
            if not raw or not raw:find("login%-container") then
                cb(nil, err and tostring(err) or _("登录失败"))
                return
            end
            self.prepared = true
            cb(true)
        end)
end

function Login:passwordAsync(phone, password, code, cb)
    self:prepare(function(ok, err)
        if not ok then cb(nil, err); return end
        self:request("POST", ORIGIN .. "/cellPhoneLogin.do", {
            operation = "login", cellPhone = phone, password = password,
            remember_me = "on", checkCode = code or "",
        }, function(raw, reason)
            if not raw then cb(nil, reason and tostring(reason) or _("登录失败")); return end
            local result = raw:match("mobileCallback%s*%(%s*['\"]([%w]+)['\"]%s*%)")
            if result == "success" then self:confirm(cb); return end
            local messages = {
                notRegistered = _("网易云阅读手机号未注册"),
                notRegisteredNeedCode = _("网易云阅读手机号未注册"),
                authenticationFailed = _("网易云阅读密码错误"),
                authFailNeedCode = _("网易云阅读密码错误"),
                errorCaptcha = _("图形验证码错误"),
            }
            cb(nil, messages[result] or _("登录失败"),
                result == "notRegisteredNeedCode" or result == "authFailNeedCode" or result == "errorCaptcha")
        end)
    end)
end

function Login:captchaAsync(cb)
    self:prepare(function(ok, err)
        if not ok then cb(nil, err); return end
        self:request("GET", ORIGIN .. "/captcha.do?d=" .. os.time() * 1000, nil, function(raw, reason)
            if not raw then cb(nil, reason and tostring(reason) or _("图形验证码加载失败")); return end
            local _ext, mime = require("utils.image").ext(raw)
            if not mime then cb(nil, _("图形验证码加载失败")); return end
            cb(raw)
        end)
    end)
end

function Login:qrCreateAsync(cb)
    self:request("GET", "https://open.weixin.qq.com/connect/qrconnect?" .. Text.formEncode({
        appid = "wxc662b4239bb6644e", redirect_uri = CALLBACK, response_type = "code",
        scope = "snsapi_login", state = "",
    }), nil, function(raw, err)
        local uuid = raw and raw:match("/connect/qrcode/([%w_%-]+)")
        if not uuid then cb(nil, err and tostring(err) or _("获取二维码失败")); return end
        cb(uuid)
    end)
end

function Login:qrPollAsync(uuid, last, cb)
    self:request("GET", "https://long.open.weixin.qq.com/connect/l/qrconnect?"
        .. Text.formEncode({ uuid = uuid, last = last, f = "json" }), nil, function(raw, err)
            if not raw then cb(nil, nil, err and tostring(err) or _("请求失败")); return end
            local ok, wire = pcall(require("json").decode, raw)
            local status = ok and type(wire) == "table" and tonumber(wire.wx_errcode)
                or tonumber(raw:match("wx_errcode%s*=%s*(%d+)"))
            local code = ok and type(wire) == "table" and wire.wx_code
                or raw:match("wx_code%s*=%s*['\"]([^'\"]+)['\"]")
            if not status or (status == 405 and (type(code) ~= "string" or code == "")) then
                cb(nil, nil, _("响应无效"))
                return
            end
            cb(status, code)
        end)
end

function Login:exchangeAsync(code, cb)
    local function follow(url, remaining)
        self:request("GET", url, nil, function(raw, err, res)
            local status = res and tonumber(res.code)
            if status and status >= 300 and status < 400 then
                local location = Request.header(res, "Location")
                if location and location:sub(1, 1) == "/" and location:sub(1, 2) ~= "//" then
                    location = ORIGIN .. location
                end
                if remaining == 0 or type(location) ~= "string"
                    or location:sub(1, #ORIGIN + 1) ~= ORIGIN .. "/" then
                    cb(nil, _("网易云阅读登录校验失败，请在浏览器重新登录"))
                    return
                end
                follow(location, remaining - 1)
                return
            end
            if not raw then cb(nil, err and tostring(err) or _("登录失败")); return end
            self:confirm(cb)
        end)
    end
    follow(CALLBACK .. "&code=" .. Text.urlEncode(code) .. "&state=", 5)
end

return Login
