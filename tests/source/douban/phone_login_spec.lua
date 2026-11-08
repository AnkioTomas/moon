--[[--
豆瓣短信登录协议及输入窗口生命周期。

@module tests.source.douban.phone_login_spec
--]]
---@diagnostic disable: undefined-field, missing-fields

local Assert = require("support.assert")
local Json = require("support.json_stub")
local Themed = require("support.theme_stubs")
local cfg, requests = {}, {}
local deferred, verified, transfer, broken, network_error = false, false, false, false, false
local phone = "+8600000000000"
package.preload["json"] = function() return Json end
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end, saveSource = function() end, get = function() return {} end }
end
package.preload["http.request"] = function()
    return {
        header = function(res, name) return res.headers[name] end,
        headerAll = function(res, name) return res.headers[name] and { res.headers[name] } or {} end,
        request = function(opts, cb)
            local req = { opts = opts }
            requests[#requests + 1] = req
            local res = { code = 200, headers = {}, body = "{}" }
            if opts.url:find("/oidc/login", 1, true) then
                res.code, res.headers.Location = 302, "https://accounts.arkread.com/oauth2/authorize?client_id=test"
            elseif opts.url:find("/oauth2/authorize", 1, true) then
                if verified then res.code, res.headers.Location = 302, "https://read.douban.com/"
                else
                    res.body = '<meta name="csrf-token" content="csrf-test">'
                    res.headers["Set-Cookie"] = "candidate=test; Path=/"
                end
            elseif opts.url:find("/phone/verify_code", 1, true) then
                res.body = broken and "{}" or Json.encode({ retry_after = 60 })
            elseif opts.url:find("/phone/verify", 1, true) then
                if broken then
                    res.code, res.body = 400, Json.encode({ code = 1001, message = "invalid code" })
                elseif transfer then res.body = Json.encode({ transfer_info = { user_type = 0 } })
                else verified = true end
            elseif opts.url == "https://read.douban.com/" then
                res.body = 'Ark.user={"id":"42","name":"测试","isAnonymous":false}'
                res.headers["Set-Cookie"] = "session=test; Path=/"
            end
            req.reply = function() cb(not network_error and res or nil, network_error and "network failed" or nil) end
            if not deferred then req.reply() end
            return { cancel = function() req.cancelled = true end }
        end,
    }
end
local Client = require("source.douban.client")
local session = Client.newLogin()
local ready, wait, user, failure
session:beginAsync(function(authorize, err) ready, failure = authorize ~= nil, err end)
Assert.is_true(ready)
Assert.is_nil(failure)
session:sendPhoneCodeAsync(phone, function(value, err) wait, failure = value, err end)
Assert.eq(wait, 60)
Assert.is_nil(failure)
local sent = requests[#requests].opts
Assert.eq(Json.decode(sent.body).phone_number, phone)
Assert.eq(sent.headers.Referer, "https://accounts.arkread.com/")
Assert.eq(sent.headers["X-CSRF-Token"], "csrf-test")
Assert.eq(sent.headers.Cookie, "candidate=test")
Assert.eq(sent.cache_ttl, 0)
broken = true
session:sendPhoneCodeAsync(phone, function(value, err) wait, failure = value, err end)
Assert.is_nil(wait)
Assert.eq(failure, "响应无效")
session:verifyPhoneAsync(phone, "000001", function(value, err) user, failure = value, err end)
Assert.is_nil(user)
Assert.eq(failure, "invalid code")
Assert.is_nil(cfg.cookie)
broken, transfer = false, true
session:verifyPhoneAsync(phone, "000001", function(value, err) user, failure = value, err end)
Assert.is_nil(user)
Assert.is_true(failure:find("历史数据授权", 1, true) ~= nil)
Assert.is_nil(cfg.cookie)
transfer = false
session:verifyPhoneAsync(phone, "000001", function(value, err) user, failure = value, err end)
Assert.eq(user.id, "42")
Assert.is_nil(failure)
Assert.is_true(Client.loggedIn())
Assert.eq(cfg.cookie, "session=test")

for cancel_at = 0, 2 do
    cfg, verified, deferred = {}, false, false
    Client.reset()
    session = Client.newLogin()
    session:beginAsync(function() end)
    deferred = true
    local calls = 0
    local job = session:verifyPhoneAsync(phone, "000001", function() calls = calls + 1 end)
    for _step = 1, cancel_at do requests[#requests].reply() end
    local current = requests[#requests]
    job.cancel()
    Assert.is_true(current.cancelled)
    current.reply()
    Assert.eq(calls, 0)
    Assert.is_nil(cfg.cookie)
    session:cancel()
end
deferred, verified, cfg = false, false, {}
Client.reset()
session = Client.newLogin()
session:beginAsync(function() end)
network_error = true
session:sendPhoneCodeAsync(phone, function(value, err) wait, failure = value, err end)
Assert.is_nil(wait)
Assert.eq(failure, "network failed")

Themed.install()
local pending, submitted, connected = {}, {}, true
package.loaded["source.douban.client"] = {
    newLogin = function()
        local candidate = {}
        function candidate:beginAsync(cb)
            self.authorize = "https://accounts.arkread.com/oauth2/authorize"
            cb(self.authorize)
            return { cancel = function() end }
        end
        function candidate:sendPhoneCodeAsync(number, cb)
            submitted[#submitted + 1] = number
            pending.send = cb
            return { cancel = function() pending.cancelled = true end }
        end
        function candidate:verifyPhoneAsync(number, code, cb)
            submitted[#submitted + 1] = number .. ":" .. code
            pending.verify = cb
            return { cancel = function() pending.cancelled = true end }
        end
        function candidate:cancel() self.cancelled = true end
        return candidate
    end,
}
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
local PhoneLogin = require("source.douban.phone_login")
local logins = 0
local dialog = PhoneLogin:new(function() logins = logins + 1 end)
dialog:start()
local input = Themed.last("input")
Assert.is_true(input.keep_open)
Assert.eq(input.fields[1].text, "+86")
input.actions[1].callback("+86", "invalid")
Assert.eq(#submitted, 0)
connected = false
input.actions[1].callback("+86", "00000000000")
Assert.eq(#submitted, 0)
connected = true
input.actions[1].callback("+86", "00000000000")
Assert.eq(submitted[1], phone)
pending.send(60)
Assert.eq(Themed.last("toast").text, "验证码已发送")
input.actions[1].callback("+86", "00000000000")
Assert.eq(#submitted, 1)
dialog:verify("+86", "different", "000001")
Assert.eq(#submitted, 1)
input.callback("+86", "00000000000", "000001")
Assert.eq(#submitted, 1)
Themed.last("confirm").ok_callback()
Assert.eq(submitted[2], phone .. ":000001")
input.cancel_callback()
Assert.is_true(pending.cancelled)
pending.verify({ id = "42" })
Assert.eq(logins, 0)
Assert.is_true(dialog.session.cancelled)

pending = {}
dialog = PhoneLogin:new(function() logins = logins + 1 end)
dialog:start()
dialog:send("+86", "00000000000")
pending.send(0)
dialog:verify("+86", "00000000000", "000001")
pending.verify({ id = "42" })
Assert.eq(logins, 1)
Assert.is_true(dialog.dialog.closed)
