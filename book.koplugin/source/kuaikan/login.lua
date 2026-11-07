--[[--
快看电脑端登录会话。匿名 Cookie、在飞请求和微信 state 归本次操作所有；
账号校验成功才保存。不同账号必须先经退出确认清理旧记录。

@module source.kuaikan.login
--]]

require("l10n").apply()
local Client = require("source.kuaikan.client")
local Mapper = require("source.kuaikan.mapper")
local Request = require("http.request")
local CookieLogin = require("source.cookie_login")
local Text = require("utils.text")
local _ = require("gettext")

local HOST = "https://www.kuaikanmanhua.com"

---@class KuaikanLogin
---@field cookies table<string, { value: string, path: string }>
---@field job HttpJob|nil
---@field serial integer
---@field revision integer
---@field previous_cookie string|nil
---@field previous_id string|nil
---@field state string|nil
---@field sms_phone string|nil
---@field sms_retry_at integer|nil
local Login = {}
Login.__index = Login

function Login.new()
    local cfg = require("utils.settings").getSource("kuaikan")
    return setmetatable({
        cookies = {}, serial = 0, revision = Client.login_revision,
        previous_cookie = cfg.cookie, previous_id = cfg.user_id,
    }, Login)
end

function Login:cancel()
    self.serial = self.serial + 1
    if self.job then self.job.cancel(); self.job = nil end
end

---@param url string
---@return string
function Login:cookie(url)
    local path = url:match("^https://www%.kuaikanmanhua%.com([^?]*)")
    if not path then return "" end
    local parts = {}
    for name, item in pairs(self.cookies) do
        if path:sub(1, #item.path) == item.path
            and (path == item.path or item.path:sub(-1) == "/" or path:sub(#item.path + 1, #item.path + 1) == "/") then
            parts[#parts + 1] = name .. "=" .. item.value
        end
    end
    table.sort(parts)
    return table.concat(parts, "; ")
end

---@param url string
---@param cb fun(raw: string|nil, err: any, res: table|nil)
---@param cookie string|nil 旧配置校验不合并其响应 Cookie
---@param fields table|nil
function Login:request(url, cb, cookie, fields)
    self:cancel()
    local serial, pending = self.serial, true
    local job = Client.loginRequestAsync(url, cookie or self:cookie(url), function(raw, err, res)
        pending = false
        if serial ~= self.serial then return end
        self.job = nil
        if self.revision ~= Client.login_revision then cb(nil, _("登录状态已变化，请重试")); return end
        if cookie == nil and url:sub(1, #HOST + 1) == HOST .. "/" then
            local default_path = url:match("^https://[^/]+([^?]*)"):match("^(.*)/") or "/"
            if default_path == "" then default_path = "/" end
            for _idx, line in ipairs(Request.headerAll(res, "Set-Cookie")) do
                local name, value = line:match("^%s*([^=;%s]+)=([^;]*)")
                local domain = line:lower():match(";%s*domain=([^;]+)")
                domain = domain and Text.trim(domain):gsub("^%.", "")
                local path = Text.trim(line:match(";%s*[Pp][Aa][Tt][Hh]=([^;]*)") or default_path)
                if path:sub(1, 1) ~= "/" then path = default_path end
                if name and (not domain or domain == "kuaikanmanhua.com" or domain == "www.kuaikanmanhua.com") then
                    local max_age = tonumber(line:lower():match(";%s*max%-age=([%-]?%d+)"))
                    if value == "" or (max_age and max_age <= 0) then self.cookies[name] = nil
                    elseif CookieLogin.parse(name .. "=" .. value) ~= "" then
                        self.cookies[name] = { value = value, path = path }
                    end
                end
            end
        end
        cb(raw, err, res)
    end, fields)
    if pending then self.job = job end
end

---@param path string
---@param fields table
---@param cb fun(ok: boolean|nil, err: string|nil)
function Login:submit(path, fields, cb)
    self:request(HOST .. path, function(raw, err)
        if not raw or err then cb(nil, err and tostring(err) or _("请求失败")); return end
        local decoded, wire = pcall(require("json").decode, raw)
        if not decoded or type(wire) ~= "table" or not tonumber(wire.code) then
            cb(nil, _("登录响应无效"))
        elseif tonumber(wire.code) == 200 then
            cb(true)
        else
            cb(nil, type(wire.message) == "string" and wire.message ~= "" and wire.message or _("登录失败"))
        end
    end, nil, fields)
end

---@param phone string
---@param captcha { ticket: string, random: string }
---@param cb fun(ok: boolean|nil, err: string|nil)
function Login:sendCodeAsync(phone, captcha, cb)
    if self.sms_retry_at and os.time() < self.sms_retry_at then
        cb(nil, _("请稍后再获取验证码"))
        return
    end
    self:submit("/v2/passport/pc/v2/get_sms_code", {
        phone = phone, ticket = captcha.ticket, random = captcha.random, verify_provider = "tencent",
    }, function(ok, err)
        if ok then self.sms_phone, self.sms_retry_at = phone, os.time() + 60 end
        cb(ok, err)
    end)
end

---@param phone string
---@param password string
---@param captcha { ticket: string, random: string }
---@param cb fun(account: table|nil, err: string|nil)
function Login:passwordAsync(phone, password, captcha, cb)
    self:submit("/v2/passport/pc/v2/mobile_pwd_login_encrypted", Mapper.passwordFields(phone, password, captcha),
        function(ok, err)
            if not ok then cb(nil, err); return end
            self:confirm(cb)
        end)
end

---@param phone string
---@param code string
---@param cb fun(account: table|nil, err: string|nil)
function Login:codeAsync(phone, code, cb)
    if phone ~= self.sms_phone or not code:match("^%d+$") then
        cb(nil, _("请先获取该手机号的验证码，再填写验证码登录"))
        return
    end
    self:submit("/v2/passport/pc/mobile_code_login", { phone = phone, code = code, remember = 1 },
        function(ok, err)
            if not ok then cb(nil, err); return end
            self:confirm(cb)
        end)
end

---@param account { user_id: string }
---@param cb fun(account: table|nil, err: string|nil)
function Login:accept(account, cb)
    local settings = require("utils.settings")
    local cfg = settings.getSource("kuaikan")
    if self.revision ~= Client.login_revision or cfg.cookie ~= self.previous_cookie or cfg.user_id ~= self.previous_id then
        cb(nil, _("登录状态已变化，请重试"))
        return
    end
    if self.previous_id and tostring(self.previous_id) ~= account.user_id then
        cb(nil, _("请先退出旧快看账号，再登录其他账号"))
        return
    end
    local cookie = self:cookie(Client.ACCOUNT_URL)
    if cookie == "" then cb(nil, _("没有读到 Cookie")); return end
    cfg.cookie, cfg.user_id, cfg.logged_in = cookie, account.user_id, true
    settings.saveSource("kuaikan")
    Client.login_revision = Client.login_revision + 1
    self.revision = Client.login_revision
    require("source.auth").ok("kuaikan")
    cb(account)
end

---@param cb fun(account: table|nil, err: string|nil)
function Login:confirm(cb)
    self:request(Client.ACCOUNT_URL, function(raw, err, res)
        local account, reason = Client.accountResponse(raw, err, res)
        if not account then cb(nil, reason); return end
        local old = CookieLogin.parse(self.previous_cookie or "")
        if not self.previous_id and old ~= "" and old ~= self:cookie(Client.ACCOUNT_URL) then
            self:request(Client.ACCOUNT_URL, function(old_raw, old_err, old_res)
                local previous, why, expired = Client.accountResponse(old_raw, old_err, old_res)
                if not previous and not expired then cb(nil, why); return end
                if not previous then
                    cb(nil, _("旧快看账号身份无法确认，请先退出旧登录后重试"))
                    return
                end
                if previous and previous.user_id ~= account.user_id then
                    cb(nil, _("请先退出旧快看账号，再登录其他账号"))
                    return
                end
                self:accept(account, cb)
            end, old)
            return
        end
        self:accept(account, cb)
    end)
end

---@param cookie string
---@param cb fun(account: table|nil, err: string|nil)
function Login:cookieAsync(cookie, cb)
    local parsed = CookieLogin.parse(cookie)
    if parsed == "" then cb(nil, _("没有读到 Cookie")); return end
    for name, value in parsed:gmatch("([^=;%s]+)=([^;]+)") do
        self.cookies[name] = { value = Text.trim(value), path = "/" }
    end
    self:confirm(cb)
end

---@param cb fun(uuid: string|nil, err: string|nil)
function Login:qrCreateAsync(cb)
    self:request(HOST .. "/v1/passport/login/pc/user_wechat_login?redirect_uri=" .. Text.urlEncode(Client.LOGIN_URL),
        function(_raw, err, res)
            local redirect = Mapper.qrLocation(Request.header(res, "Location"))
            if not res or tonumber(res.code) ~= 302 or not redirect then
                cb(nil, err and tostring(err) or _("获取二维码失败"))
                return
            end
            self.state = redirect.state
            self:request(redirect.url, function(raw, reason)
                local uuid = raw and raw:match("/connect/qrcode/([%w_%-]+)")
                if not uuid then cb(nil, reason and tostring(reason) or _("获取二维码失败")); return end
                cb(uuid)
            end)
        end)
end

---@param uuid string
---@param last integer|nil
---@param cb fun(status: integer|nil, code: string|nil, err: string|nil)
function Login:qrPollAsync(uuid, last, cb)
    self:request("https://long.open.weixin.qq.com/connect/l/qrconnect?"
        .. Text.formEncode({ uuid = uuid, last = last or 408, f = "json" }), function(raw, err)
            if not raw then cb(nil, nil, err and tostring(err) or _("请求失败")); return end
            local status, code = Mapper.qrStatus(raw)
            cb(status, code, not status and _("登录响应无效") or nil)
        end)
end

---@param code string
---@param cb fun(account: table|nil, err: string|nil)
function Login:exchangeAsync(code, cb)
    local function follow(url, remaining)
        self:request(url, function(raw, err, res)
            local status = res and tonumber(res.code)
            if status and status >= 300 and status < 400 then
                local location = Request.header(res, "Location")
                if type(location) == "string" and location:sub(1, 1) == "/" and location:sub(1, 2) ~= "//" then
                    location = HOST .. location
                end
                if remaining == 0 or type(location) ~= "string" or location:sub(1, #HOST + 1) ~= HOST .. "/" then
                    cb(nil, _("登录响应无效"))
                    return
                end
                follow(location, remaining - 1)
                return
            end
            if not raw or err then cb(nil, err and tostring(err) or _("登录失败")); return end
            self:confirm(cb)
        end)
    end
    if not self.state or type(code) ~= "string" or code == "" then cb(nil, _("登录响应无效")); return end
    follow(Mapper.WECHAT_CALLBACK .. "?" .. Text.formEncode({ code = code, state = self.state }), 5)
end

return Login
