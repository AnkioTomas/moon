--[[--
知音漫客短信、密码与 Cookie 登录：官网字段、账号兑换、取消和换号隔离。

@module tests.source.zymk.login_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field

local Assert = require("support.assert")
local JSON = require("support.json_stub")
local Text = require("utils.text")
local Themed = require("support.theme_stubs")
Themed.install()
package.loaded["json"] = JSON
local cfg, requests, reloads, expired, connected = {}, {}, 0, false, true
local synchronous
package.loaded["utils.settings"] = { getSource = function() return cfg end, saveSource = function() end }
package.loaded["source.registry"] = { reload = function() reloads = reloads + 1 end }
package.loaded["source.auth"] = {
    expired = function() return expired end, ok = function() expired = false end,
}
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
package.loaded["ui.themes.widgets.row"] = { widget = function(opts) return opts end }
local function request(url, body, opts, cb)
    local r = { url = url, body = body, opts = opts, cb = cb }
    requests[#requests + 1] = r
    if synchronous then local answer = synchronous; synchronous = nil; cb(answer) end
    return { cancel = function() r.cancelled = true end }
end
package.loaded["http.request"] = {
    post = request,
}
local Login = require("source.zymk.login")
local Setting = require("source.zymk.setting")
local Mapper = require("source.zymk.mapper")
local response = JSON.encode({ status = 0, data = { openid = "account-a", type = "mkxq" } })
local token = JSON.encode({ status = 0, data = { appToken = "temporary-token" } })
local phone = "13800000000"
local account, reason
local function done(value, err) account, reason = value, err end
local session = Login.new()
Assert.is_false(Login.hasAccount())
Assert.is_nil(Mapper.account({ openid = "guest", type = "device" }))
session:sendSmsAsync(phone, nil, false, done)
Assert.matches(requests[#requests].url, "/apinew/sendsms/$")
Assert.matches(requests[#requests].body, "service=zymk")
Assert.matches(requests[#requests].body, "refresh=0")
local captcha = { Image = "image", Width = 320, Height = 120, Content = "文字" }
requests[#requests].cb(JSON.encode({ status = 1031, data = captcha }))
Assert.eq(account.width, 320)
Assert.is_nil(session.sms_phone)
session:sendSmsAsync(phone, { { x = 10, y = 20 }, { x = 50, y = 30 } }, false, done)
local body = Text.urlDecode(requests[#requests].body)
Assert.matches(body, '"appId":11')
Assert.matches(body, '"verificaType":2')
requests[#requests].cb(JSON.encode({ status = 0 }))
Assert.eq(session.sms_phone, phone)
Assert.is_true(account.sent)
local count = #requests
session:sendSmsAsync(phone, nil, false, done)
Assert.eq(#requests, count)
Assert.eq(reason, "请稍后再获取验证码")
session:codeAsync("13900000000", "123456", done)
Assert.eq(#requests, count)
Assert.eq(reason, "请先获取该手机号的验证码，再填写验证码登录")
session:codeAsync(phone, "123456", done)
Assert.matches(requests[#requests].url, "/apinew/mobilevclogin/$")
Assert.matches(requests[#requests].body, "vcode=123456")
Assert.is_nil(cfg.account)
requests[#requests].cb(token)
Assert.matches(requests[#requests].url, "/apinew/getuserinfo/$")
Assert.matches(requests[#requests].body, "token=temporary%-token")
Assert.is_false(requests[#requests].opts.allow_redirects)
Assert.eq(requests[#requests].opts.headers.Origin, "https://www.zymk.cn")
Assert.eq(requests[#requests].opts.headers.Referer, "https://www.zymk.cn/login.htm")
Assert.eq(requests[#requests].opts.headers["X-Requested-With"], "XMLHttpRequest")
Assert.is_nil(cfg.account)
requests[#requests].cb(response)
Assert.eq(account.openid, "account-a")
Assert.is_nil(cfg.account.appToken)
Assert.is_nil(cfg.password)
Assert.eq(reloads, 1)
Assert.is_true(Login.hasAccount())
expired = true
Assert.is_false(Login.hasAccount())
expired = false
local previous = cfg.account
Login.new():confirm({ type = "mkxq", token = "expired" }, done)
requests[#requests].cb(nil, "network failed")
Assert.eq(reason, "network failed")
Assert.eq(cfg.account, previous)
Login.new():confirm({ type = "mkxq", token = "bad" }, done)
requests[#requests].cb("<html>login</html>")
Assert.eq(reason, "登录响应无效")
Assert.eq(cfg.account, previous)
Login.new():confirm({ type = "mkxq", token = "other" }, done)
requests[#requests].cb(JSON.encode({ status = 0, data = { openid = "account-b", type = "mkxq" } }))
Assert.eq(reason, "请先退出旧知音漫客账号，再登录其他账号")
Assert.eq(cfg.account, previous)
local stale = Login.new()
stale:confirm({ type = "mkxq", token = "old" }, done)
cfg.account = nil
requests[#requests].cb(response)
Assert.eq(reason, "登录状态已变化，请重试")
Assert.is_nil(cfg.account)

session = Login.new()
session.sms_phone = phone
synchronous = token
session:codeAsync(phone, "123456", done)
local pending = requests[#requests]
session:cancel()
Assert.is_true(pending.cancelled)
account = nil
pending.cb(response)
Assert.is_nil(account)
Assert.is_nil(cfg.account)

session = Login.new()
session:passwordAsync("reader@example.test", "  p+a&ss  ", done)
Assert.matches(requests[#requests].url, "/userapi/login/$")
Assert.eq(requests[#requests].body, Text.formEncode({ identity = "reader@example.test", pwd = "  p+a&ss  " }))
requests[#requests].cb(token)
Assert.is_nil(cfg.account)
requests[#requests].cb(response)
Assert.is_true(Login.hasAccount())
Assert.is_nil(cfg.password)
Assert.is_nil(Mapper.captcha({ Width = 320, Height = 120 }))

package.loaded["source.logout"] = { row = function() return function() return { title = "退出登录" } end end }
local rows = Setting.rows()
Assert.eq(#rows, 4)
Assert.eq(rows[1](400).title, "短信验证码登录")
Assert.eq(rows[2](400).title, "密码登录")
Assert.eq(rows[3](400).title, "粘贴 Cookie")
for _index, row in ipairs(rows) do
    local title = row(400).title
    Assert.is_true(title ~= "微信扫码登录" and title ~= "电脑浏览器登录")
end
rows[2](400).callback()
Assert.eq(Themed.last("input").fields[2].text_type, "password")
Themed.last("input").callback("reader", "password")
pending = requests[#requests]
Themed.last("progress_dialog").on_cancel()
Assert.is_true(pending.cancelled)
pending.cb(token)
Assert.eq(#Setting.rows(), 4)
local cookie = "user=" .. Text.urlEncode(JSON.encode({ openid = "account-a", type = "mkxq" }))
local cookie_previous = cfg.account
Login.new():cookieAsync(cookie, done)
requests[#requests].cb(nil, "network failed")
Assert.eq(cfg.account, cookie_previous)
Assert.eq(reason, "network failed")
Login.new():cookieAsync(cookie, done)
Assert.matches(requests[#requests].body, "openid=account%-a")
Assert.matches(requests[#requests].body, "type=mkxq")
requests[#requests].cb(response)
Assert.is_true(Login.hasAccount())
Login.new():cookieAsync(cookie, done)
requests[#requests].cb(JSON.encode({ status = 0, data = { openid = "wrong-account", type = "mkxq" } }))
Assert.eq(reason, "登录响应无效")
rows[3](400).callback()
Themed.last("input").callback(cookie)
pending = requests[#requests]
Themed.last("progress_dialog").on_cancel()
Assert.is_true(pending.cancelled)
local cookie_count = #requests
pending.cb(response)
Assert.eq(#requests, cookie_count)
count = #requests
Login.new():cookieAsync("unrelated=1", done)
Assert.eq(#requests, count)
Assert.eq(reason, "没有读到知音漫客登录 Cookie")
local sms = require("source.zymk.phone_login").new(function() end)
sms:start()
Assert.eq(Themed.last("input").fields[1].input_type, "number")
count = #requests
connected = false
Themed.last("input").callback(phone)
Assert.eq(#requests, count)
Assert.eq(Themed.last("toast").text, "网络不可用，请先连接 Wi-Fi")
connected = true
sms:start()
Themed.last("input").callback(phone)
pending = requests[#requests]
Themed.last("progress_dialog").on_cancel()
Assert.is_true(pending.cancelled)
pending.cb(JSON.encode({ status = 0 }))
Assert.is_nil(sms.session.sms_phone)
sms = require("source.zymk.phone_login").new(function() end)
sms:start()
Themed.last("input").callback(phone)
requests[#requests].cb(JSON.encode({ status = 0 }))
local code_input = Themed.last("input")
Assert.eq(code_input.fields[1].label, "验证码")
count = #requests
code_input.actions[1].callback()
Assert.eq(#requests, count)
Assert.eq(Themed.last("input"), code_input)
Assert.eq(Themed.last("toast").text, "请稍后再获取验证码")
sms:cancel()
