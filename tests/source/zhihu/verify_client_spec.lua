--[[--
知乎官方挑战创建、票据验证和同会话解除风控。

@module tests.source.zhihu.verify_client_spec
--]]
---@diagnostic disable: undefined-field

package.loaded["json"] = require("support.json_stub")
local Json = require("support.json_stub")
local Assert = require("support.assert")
local calls = {}
local scripts = { "https://cstaticdun.126.net/load.min.js",
    "https://captcha.zhihu.com/api/v1/captcha/js?appId=lsxNQs26Wva2&sessionId=challenge%2Bfixture" }
local success, block_code = true, 0
local defer, pending, cancelled, fail_code
local function response(wire, headers, code)
    return { code = code or 200, body = Json.encode(wire), headers = headers }
end
package.loaded["http.request"] = {
    ok = function(code) return code >= 200 and code < 300 end,
    headerAll = function(res, name) return res and res.headers and res.headers[name] or {} end,
    post = function(url, body, opts, cb)
        calls[#calls + 1] = { url = url, body = body, headers = opts.headers }
        cb(Json.encode({ script = scripts }), nil, response({}, { ["Set-Cookie"] = { "captcha_session=issued; Path=/" } }))
        return { cancel = function() end }
    end,
    request = function(opts, cb)
        calls[#calls + 1] = opts
        if defer then
            pending = cb
            return { cancel = function() cancelled = true end }
        end
        if fail_code then cb(response({ error = { message = "rejected" } }, nil, fail_code), "HTTP " .. fail_code)
        elseif opts.method == "PUT" then
            cb(response({ success = success }, { ["Set-Cookie"] = { "verified=accepted; Path=/" } }))
        elseif opts.method == "POST" then cb(response({}))
        else cb(response({ code = block_code })) end
        return { cancel = function() end }
    end,
}
package.loaded["source.zhihu.client"] = nil
local Client = require("source.zhihu.client")
local session = { jar = { d_c0 = "device", _xsrf = "xsrf" }, challenge_id = "appeal+fixture" }
local config, failure
Client.qrCaptchaAsync(session, function(value, err) config, failure = value, err end)
Assert.is_nil(failure)
Assert.eq(config.session_id, "challenge+fixture")
Assert.eq(calls[1].url, "https://captcha.zhihu.com/api/v1/captcha")
Assert.eq(Json.decode(calls[1].body).appId, "lsxNQs26Wva2")
Assert.is_true(calls[1].headers.Cookie:find("d_c0=device", 1, true) ~= nil)
Assert.eq(session.jar.captcha_session, "issued")

local ok
Client.qrVerifyAsync(session, config.session_id, '{"validate":"user-proof"}', function(value, err) ok, failure = value, err end)
Assert.is_true(ok)
Assert.is_nil(failure)
Assert.eq(calls[2].method, "PUT")
Assert.eq(calls[2].url, "https://captcha.zhihu.com/api/v1/captcha")
local body = Json.decode(calls[2].body)
Assert.eq(body.sessionId, "challenge+fixture")
Assert.eq(body.ticket, '{"validate":"user-proof"}')
Assert.eq(calls[3].url, "https://www.zhihu.com/api/v4/anticrawl/new_captcha_appeal")
Assert.eq(calls[3].method, "POST")
Assert.eq(Json.decode(calls[3].body).session, "appeal+fixture")
Assert.eq(calls[3].headers["x-xsrftoken"], "xsrf")
Assert.is_true(calls[3].headers.Cookie:find("verified=accepted", 1, true) ~= nil)
Assert.eq(calls[4].method, "GET")
Assert.eq(calls[4].url, "https://www.zhihu.com/api/v4/anticrawl/new_captcha_appeal?session=appeal%2Bfixture")

success = false
local before = #calls
Client.qrVerifyAsync(session, "id", "{}", function(value, err) ok, failure = value, err end)
Assert.is_false(ok)
Assert.eq(failure, "验证失败，请重新验证")
Assert.eq(#calls, before + 1, "控件验证失败不能继续解除风控")
success = true
block_code = 40352
Client.qrVerifyAsync(session, "id", "{}", function(value, err) ok, failure = value, err end)
Assert.is_false(ok, "官方仍然阻止时不能返回验证成功")
Assert.eq(failure, "验证失败，请重新验证")
block_code = 0
fail_code = 403
Client.qrVerifyAsync(session, "id", "{}", function(value, err) ok, failure = value, err end)
Assert.is_false(ok)
Assert.eq(failure, "rejected")
fail_code = nil

defer = true
local called = false
local handle = Client.qrVerifyAsync(session, "id", "{}", function() called = true end)
before = #calls
handle.cancel()
Assert.is_true(cancelled)
pending(response({ success = true }))
Assert.is_false(called)
Assert.eq(#calls, before)

scripts = { "https://cstaticdun.126.net/load.min.js", "https://captcha.zhihu.com.evil.test/api/v1/captcha/js?sessionId=x" }
Client.qrCaptchaAsync(session, function(value, err) config, failure = value, err end)
Assert.is_nil(config)
Assert.eq(failure, "知乎登录响应异常，请重新获取二维码")
