--[[--
电脑端密码 / 微信登录：隔离会话、错误分支、跳转、取消与 Cookie 替换。

@module tests.source.netease.auth_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
package.loaded["json"] = require("support.json_stub")
local cfg, saves = { cookie = "OLD=valid", logged_in = true, csrf = "old" }, 0
package.loaded["utils.settings"] = {
    getSource = function() return cfg end,
    saveSource = function() saves = saves + 1 end,
}
local requests, cancelled = {}, 0
local sync_prepare = false
local function send(method, url, body, opts, cb)
    requests[#requests + 1] = { method = method, url = url, body = body, opts = opts, cb = cb }
    if sync_prepare and url:find("/loginForm.do", 1, true) then
        cb('<div id="login-container"></div>', nil, { headers = { ["Set-Cookie"] = { "ANON=1; Path=/" } } })
    end
    return { cancel = function() cancelled = cancelled + 1 end }
end
package.loaded["http.request"] = {
    get = function(url, opts, cb) return send("GET", url, nil, opts, cb) end,
    post = function(url, body, opts, cb) return send("POST", url, body, opts, cb) end,
    header = function(res, name) return res and res.headers[name] end,
    headerAll = function(res, name) return res and res.headers and res.headers[name] or {} end,
}
local Login = require("source.netease.auth")
local ok, err, needs_code, calls
local function done(value, reason, code) ok, err, needs_code, calls = value, reason, code, (calls or 0) + 1 end
local function reply(body, cookies, code, location)
    requests[#requests].cb(body, nil, {
        code = code or 200, headers = { ["Set-Cookie"] = cookies or {}, Location = location },
    })
end
local account = '<title>个人资料--网易云阅读</title><a id="editNickName"></a>'
local function prepare(session)
    session:passwordAsync("13800138000", " secret with spaces ", nil, done)
    reply('<div id="login-container"></div>', { "ANON=first; Path=/; HttpOnly; SameSite=Lax" })
end
local session = Login.new()
prepare(session)
Assert.matches(requests[#requests].url, "yuedu%.163%.com/cellPhoneLogin%.do")
Assert.matches(requests[#requests].body, "cellPhone=13800138000")
Assert.is_true(requests[#requests].body:find("password=%20secret%20with%20spaces%20", 1, true) ~= nil)
Assert.eq(requests[#requests].opts.headers.Cookie, "ANON=first")
reply("<script>oWin.YD.Header.mobileCallback('authenticationFailed');</script>")
Assert.is_nil(ok)
Assert.eq(err, "网易云阅读密码错误")
Assert.eq(cfg.cookie, "OLD=valid")
Assert.eq(saves, 0)
session:passwordAsync("13800138000", "good", nil, done)
reply("<script>oWin.YD.Header.mobileCallback('authFailNeedCode');</script>")
Assert.is_true(needs_code)
session:passwordAsync("13800138000", "good", "ab12", done)
Assert.matches(requests[#requests].body, "checkCode=ab12")
reply("<script>oWin.YD.Header.mobileCallback('success');</script>", {
    'ANON=""; Path=/', "NTES=desktop; Path=/; HttpOnly",
})
Assert.eq(cfg.cookie, "OLD=valid", "服务端声称成功后仍须校验")
Assert.eq(requests[#requests].opts.headers.Cookie, "NTES=desktop")
reply(account)
Assert.is_true(ok)
Assert.eq(cfg.cookie, "NTES=desktop")
Assert.is_nil(cfg.csrf)
Assert.eq(saves, 1)

session = Login.new()
prepare(session)
reply("<script>mobileCallback('success')</script>", { "NTES=invalid; Path=/" })
reply("<title>登录--网易云阅读</title>")
Assert.is_nil(ok)
Assert.eq(cfg.cookie, "NTES=desktop")
Assert.eq(saves, 1)
session = Login.new()
session:qrCreateAsync(done)
Assert.is_nil(requests[#requests].opts.headers, "微信不能收到网易 Cookie")
Assert.matches(requests[#requests].url, "appid=wxc662b4239bb6644e")
reply('<img src="/connect/qrcode/uuid_123">')
Assert.eq(ok, "uuid_123")
session:qrPollAsync("uuid_123", 404, done)
Assert.matches(requests[#requests].url, "last=404")
reply('{"wx_errcode":405,"wx_code":"code_123"}')
Assert.eq(ok, 405)
Assert.eq(err, "code_123")
session:qrPollAsync("uuid_123", nil, done)
reply('window.wx_errcode=408;window.wx_code="";')
Assert.eq(ok, 408)
session:qrPollAsync("uuid_123", nil, done)
reply('{"wx_errcode":405}')
Assert.is_nil(ok)
Assert.eq(needs_code, "响应无效")
session:exchangeAsync("code_123", done)
Assert.matches(requests[#requests].url, "site=7&from=login&fromHttps=true&code=code_123")
reply(nil, { "NTES=wechat; Path=/" }, 302, "/myinfor.do")
Assert.eq(requests[#requests].opts.headers.Cookie, "NTES=wechat")
reply(account)
reply(account)
Assert.is_true(ok)
Assert.eq(cfg.cookie, "NTES=wechat")
session:exchangeAsync("bad_redirect", done)
reply(nil, {}, 302, "https://example.com/steal")
Assert.is_nil(ok)
Assert.eq(cfg.cookie, "NTES=wechat")
Assert.is_nil(requests[#requests].url:find("example.com", 1, true))

sync_prepare = true
session = Login.new()
session:passwordAsync("13800138000", "good", nil, done)
Assert.matches(requests[#requests].url, "/cellPhoneLogin%.do")
local late, before = requests[#requests].cb, calls
session:cancel()
Assert.eq(cancelled, 1, "同步 prepare 回调不能覆盖在途 POST 的句柄")
late("<script>mobileCallback('success')</script>")
Assert.eq(calls, before)
Assert.eq(cfg.cookie, "NTES=wechat")
session:passwordAsync("13800138000", "good", nil, done)
reply("<script>mobileCallback('errorCaptcha')</script>")
Assert.is_true(needs_code, "取消一次请求后仍能在原登录窗重试")
