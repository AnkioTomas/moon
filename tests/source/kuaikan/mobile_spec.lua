--[[--
快看密码加密与短信登录会话：实际 Web 字段、错误、冷却、账号确认及阶段取消。

@module tests.source.kuaikan.mobile_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field

local Assert = require("support.assert")
local JSON = require("support.json_stub")
local Text = require("utils.text")
package.loaded["json"] = JSON
local cfg, requests, saves = { cookie = "sid=old", user_id = "7" }, {}, 0
package.loaded["utils.settings"] = {
    getSource = function() return cfg end, saveSource = function() saves = saves + 1 end,
}
package.loaded["source.auth"] = { ok = function() end }
local Request = {
    header = function() end,
    headerAll = function(res) return res and res.cookies or {} end,
}
local function record(url, body, opts, cb)
    local fields = {}
    for key, value in (body or ""):gmatch("([^&=]+)=([^&]*)") do fields[Text.urlDecode(key)] = Text.urlDecode(value) end
    local r = { url = url, body = body, fields = fields, opts = opts, cb = cb }
    requests[#requests + 1] = r
    return { cancel = function() r.cancelled = true end }
end
Request.get = function(url, opts, cb) return record(url, nil, opts, cb) end
Request.post = record
package.loaded["http.request"] = Request
local Mapper = require("source.kuaikan.mapper")
local Client = require("source.kuaikan.client")
local Login = require("source.kuaikan.login")
local phone, proof = "+86-13800000000", { ticket = "captcha-proof", random = "random-proof" }
Assert.eq(Mapper.phone(" +86 ", "13800000000 "), phone)
Assert.eq(Mapper.phone("+852", "12345678"), "+852-12345678")
Assert.is_nil(Mapper.phone("+86", "12345678"))
Assert.is_nil(Mapper.phone("86", "13800000000"))
Assert.is_nil(Mapper.phone("+1", "12"))
local fields = Mapper.passwordFields(phone, " pass测试 😀 ", proof)
Assert.eq(fields.phone, "YhyUbUo+Y1hLLsQUeDEwwg==")
Assert.eq(fields.password, "DNsZnApMIYKSb60EXagwMryIBWUDl2peUULxGpgYDOQ=")
Assert.eq(fields.verify_provider, "tencent")
local good = JSON.encode({ code = 200 })
local account = JSON.encode({ code = 200, data = { user_info = { authenticate = 1, user_id = 7 } } })
local value, reason
local function answer(v, err) value, reason = v, err end
local session = Login.new()
session:passwordAsync(phone, " pass测试 😀 ", proof, answer)
local r = requests[#requests]
Assert.matches(r.url, "/v2/passport/pc/v2/mobile_pwd_login_encrypted$")
Assert.eq(r.opts.content_type, "application/x-www-form-urlencoded")
Assert.eq(r.opts.cache_ttl, 0)
Assert.is_nil(r.opts.headers.Cookie)
Assert.is_nil(r.body:find(phone, 1, true))
Assert.is_nil(r.body:find(Text.urlEncode(" pass测试 😀 "), 1, true))
Assert.eq(r.fields.password, fields.password)
r.cb(good, nil, { cookies = { "sid=new; Path=/" } })
Assert.eq(requests[#requests].url, Client.ACCOUNT_URL)
Assert.eq(cfg.cookie, "sid=old")
requests[#requests].cb(account)
Assert.eq(value.user_id, "7")
Assert.eq(cfg.cookie, "sid=new")
Assert.eq(saves, 1)
Assert.is_nil(cfg.password)

session = Login.new()
session:passwordAsync(phone, "bad", proof, answer)
r = requests[#requests]
r.cb(JSON.encode({ code = 400, message = "password refused" }))
Assert.is_nil(value)
Assert.eq(reason, "password refused")
Assert.eq(cfg.cookie, "sid=new")
for _idx, response in ipairs({ "broken", "[]", "{}", '{"code":200}' }) do
    session:passwordAsync(phone, "test", proof, answer)
    r = requests[#requests]
    r.cb(response)
    if response == '{"code":200}' then requests[#requests].cb(nil, "offline") end
    Assert.is_nil(value)
    Assert.is_true(type(reason) == "string")
    Assert.eq(saves, 1)
end

cfg = {}
session = Login.new()
session:sendCodeAsync(phone, proof, answer)
r = requests[#requests]
Assert.matches(r.url, "/v2/passport/pc/v2/get_sms_code$")
Assert.eq(r.fields.phone, phone)
Assert.eq(r.fields.random, "random-proof")
r.cb(JSON.encode({ code = 400, message = "SMS refused" }))
Assert.is_nil(session.sms_phone)
Assert.eq(reason, "SMS refused")
session:sendCodeAsync(phone, proof, answer)
requests[#requests].cb(good, nil, { cookies = { "nonce=anonymous; Path=/" } })
Assert.is_true(value)
Assert.eq(session.sms_phone, phone)
local count = #requests
session:sendCodeAsync(phone, proof, answer)
Assert.eq(#requests, count)
Assert.eq(reason, "请稍后再获取验证码")
session:codeAsync("+86-13900000000", "123456", answer)
Assert.eq(#requests, count)
session:codeAsync(phone, "invalid", answer)
Assert.eq(#requests, count)
session:codeAsync(phone, "123456", answer)
r = requests[#requests]
Assert.matches(r.url, "/v2/passport/pc/mobile_code_login$")
Assert.eq(r.fields.code, "123456")
Assert.eq(r.opts.headers.Cookie, "nonce=anonymous")
r.cb(good, nil, { cookies = { "sid=sms; Path=/" } })
requests[#requests].cb(account)
Assert.eq(cfg.cookie, "nonce=anonymous; sid=sms")
Assert.is_nil(cfg.code)

local get = Request.get
Request.post = function(url, body, opts, cb)
    cb(good, nil, { cookies = { "sid=sync; Path=/" } })
    return { cancel = function() error("completed POST must not overwrite account request") end }
end
session = Login.new()
session:passwordAsync(phone, "test", proof, answer)
r = requests[#requests]
session:cancel()
Assert.is_true(r.cancelled)
r.cb(account)
Assert.eq(cfg.cookie, "nonce=anonymous; sid=sms")
Request.get = get
