--[[--
起点官方 Web 短信登录会话。图形验证与短信使用不同 sessionKey，不保存手机号或验证码。

@module source.qidian.login
--]]

require("l10n").apply()
local JSON = require("json")
local Request = require("http.request")
local Text = require("utils.text")
local CookieLogin = require("source.cookie_login")
local _ = require("gettext")

local BASE = "https://ptlogin.yuewen.com"
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36"
local LOGIN_KEYS = { ywguid = true, ywkey = true, ywopenid = true }
local HOSTS = { ["ptlogin.yuewen.com"] = true, ["passport.yuewen.com"] = true,
    ["passport.qidian.com"] = true, ["m.qidian.com"] = true }

---@class QidianLogin
---@field jar table<string, string>
---@field webjar table<string, string>
---@field generation integer
---@field job HttpJob|nil
---@field initialized boolean|nil
---@field challenge_key string|nil
---@field sms_key string|nil
---@field cancelled boolean|nil
local Login = {}
Login.__index = Login

function Login.new()
    return setmetatable({ jar = {}, webjar = {}, generation = 0 }, Login)
end

function Login:cancel()
    self.cancelled = true
    self:interrupt()
    self.sms_key, self.challenge_key = nil, nil
    self.jar, self.webjar = {}, {}
end

function Login:interrupt()
    self.generation = self.generation + 1
    if self.job then self.job.cancel() end
    self.job = nil
end

local function cookies(jar)
    local parts = {}
    for name, value in pairs(jar) do parts[#parts + 1] = name .. "=" .. value end
    return CookieLogin.parse(table.concat(parts, "; "))
end

local function absorb(jar, res, only_login)
    for _idx, line in ipairs(Request.headerAll(res, "Set-Cookie")) do
        local name, value = line:match("^%s*([^=%s;]+)=([^;]*)")
        if name and (not only_login or LOGIN_KEYS[name:lower()]) then
            name = only_login and name:lower() or name
            jar[name] = value ~= "" and value or nil
        end
    end
end

function Login:_get(url, cb)
    if self.cancelled then return end
    local host = url:match("^https://([^/?#]+)")
    if not HOSTS[host] then cb(nil, _("起点登录跳转地址无效")); return end
    local headers = { ["User-Agent"] = UA, Referer = "https://passport.qidian.com/mobile/login" }
    if host == "ptlogin.yuewen.com" then headers.Cookie = cookies(self.jar)
    elseif host == "m.qidian.com" then headers.Cookie = cookies(self.webjar) end
    local pending, gen = true, self.generation
    local job = Request.request({
        url = url, method = "GET", headers = headers, allow_redirects = false,
        timeout = require("http.timeout").net(1), cache_ttl = 0,
    }, function(res, err)
        pending = false
        if self.cancelled or gen ~= self.generation then return end
        self.job = nil
        if not res or err then cb(nil, err and tostring(err) or _("请求失败")); return end
        local status = tonumber(res.code)
        if not status or status < 200 or status >= 400 then cb(nil, "HTTP " .. tostring(res.code)); return end
        if host == "ptlogin.yuewen.com" then absorb(self.jar, res, false) end
        absorb(self.webjar, res, true)
        cb(res)
    end)
    if pending then self.job = job end
end

function Login:baseParams()
    return {
        appId = "13", areaId = "31", source = "", returnurl = "https://m.qidian.com/",
        version = "", imei = "", qimei = "", target = "top", ticket = "1",
        autotime = "14", jumpdm = "qidian", ajaxdm = "", auto = self.jar.al or "", sdkversion = "",
        format = "json", method = "moonLogin",
    }
end

function Login:_json(path, fields, cb)
    local params = self:baseParams()
    for key, value in pairs(fields) do params[key] = value end
    self:_get(BASE .. path .. "?" .. Text.formEncode(params), function(res, err)
        if not res then cb(nil, err); return end
        local ok, wire = pcall(JSON.decode, res.body)
        if not ok or type(wire) ~= "table" then cb(nil, _("起点登录响应无效")); return end
        if tonumber(wire.code) ~= 0 then
            cb(nil, wire.message or wire.msg or (_("登录失败") .. "：" .. tostring(wire.code))); return
        end
        if type(wire.data) ~= "table" then cb(nil, _("起点登录响应无效")); return end
        cb(wire.data)
    end)
end

function Login:beginAsync(cb)
    self:_json("/userSdk/getvalidatecode", { force = 1 }, function(data, err)
        if not data then cb(nil, err); return end
        self.initialized = true
        if type(data.imgSrc) == "string" and data.imgSrc ~= "" then self.challenge_key = data.sessionKey end
        cb(data)
    end)
end

function Login:imageAsync(url, cb)
    local target = Text.absoluteUrl(BASE .. "/", url)
    if not target then cb(nil, _("起点验证码响应无效")); return end
    self:_get(target, function(res, err)
        if not res then cb(nil, err); return end
        local body = res.body
        if type(body) ~= "string" or #body > 1024 * 1024 then cb(nil, _("起点验证码图片无效")); return end
        local ext, mime = require("utils.image").ext(body)
        if not ext then cb(nil, _("起点验证码图片无效")); return end
        cb("data:" .. mime .. ";base64," .. Text.base64Encode(body))
    end)
end

function Login:sendCodeAsync(country, phone, proof, cb)
    self:_json("/userSdk/sendmsgnew", {
        phoneIsAbroad = country == "+86" and 0 or 1, inputUserId = country .. phone,
        sessionKey = self.challenge_key or "", type = 1, validateCode = proof or "", needRegister = 0,
    }, function(data, err)
        if not data then cb(nil, err); return end
        local action = tonumber(data.nextAction)
        if action == 0 then
            if type(data.sessionKey) ~= "string" or data.sessionKey == "" then
                cb(nil, _("起点短信会话缺失")); return
            end
            self.sms_key = data.sessionKey
            self.challenge_key = nil
        elseif action == 8 or action == 11 then
            if type(data.sessionKey) ~= "string" or data.sessionKey == "" or type(data.imgSrc) ~= "string"
                or data.imgSrc == "" then cb(nil, _("起点验证码响应无效")); return end
            self.challenge_key = data.sessionKey
        else
            cb(nil, _("起点登录需要未支持的验证") .. "：" .. tostring(data.nextAction)); return
        end
        cb(data)
    end)
end

function Login:_exchange(data, cb)
    for name, key in pairs({ ywguid = "ywGuid", ywkey = "ywKey", ywopenid = "ywOpenId" }) do
        local value = data[key]
        if type(value) == "number" then self.webjar[name] = string.format("%.0f", value)
        elseif type(value) == "string" then self.webjar[name] = value end
    end
    local url = data["302url"]
    if not url and type(data.ticket) == "string" and data.ticket ~= "" then
        url = "https://m.qidian.com/?" .. Text.formEncode({
            ticket = data.ticket, ywguid = self.webjar.ywguid or "", ywOpenId = self.webjar.ywopenid or "",
        })
    end
    if type(url) ~= "string" or url == "" then cb(nil, _("起点登录缺少会话兑换凭据")); return end
    local function follow(target, hop)
        if hop > 5 then cb(nil, _("起点登录跳转过多")); return end
        self:_get(target, function(res, err)
            if not res then cb(nil, err); return end
            local status = tonumber(res.code)
            local location = Request.header(res, "Location")
            if status >= 300 then
                local next_url = Text.absoluteUrl(target, location)
                if not next_url then cb(nil, _("起点登录跳转地址无效")); return end
                follow(next_url, hop + 1)
            elseif target:match("^https://([^/?#]+)") ~= "m.qidian.com" or not self.webjar.ywguid
                or not self.webjar.ywkey then
                cb(nil, _("起点登录未获取到本站会话"))
            else
                cb(cookies(self.webjar) .. "; _csrfToken=" .. require("utils.random").hex(16))
            end
        end)
    end
    follow(url, 1)
end

function Login:verifyAsync(phone, code, cb)
    if not self.sms_key then cb(nil, _("请先获取验证码")); return end
    self:_json("/userSdk/phonecodelogin", {
        inputUserId = phone, sessionKey = self.sms_key, validateCode = code,
    }, function(data, err)
        if not data then cb(nil, err); return end
        if tonumber(data.nextAction) ~= 0 then cb(nil, _("起点登录需要未支持的验证")); return end
        self:_exchange(data, cb)
    end)
end

return Login
