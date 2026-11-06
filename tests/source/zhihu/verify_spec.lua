--[[--
知乎独立验证页：临时票据、同会话提交、失败重试与取消。

@module tests.source.zhihu.verify_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
local Ext = require("utils.extension")
Ext.reset()
local timers = {}
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_self, _delay, fn) timers[fn] = true end,
    unschedule = function(_self, fn) timers[fn] = nil end,
}
package.loaded["ui.guard"] = { wrap = function(_label, fn) return fn end }

local config_done, verify_done, config_cancelled, verify_cancelled
local received_session, received_id, received_result
package.loaded["source.zhihu.client"] = {
    qrCaptchaAsync = function(session, cb)
        received_session, config_done = session, cb
        return { cancel = function() config_cancelled = true end }
    end,
    qrVerifyAsync = function(session, id, result, cb)
        received_session, received_id, received_result, verify_done = session, id, result, cb
        return { cancel = function() verify_cancelled = true end }
    end,
}
local path
Ext.add("web.open_page", function(url, _title, _text, opts)
    path = url
    return require("ui.themes.widgets.qr"):new{ close_callback = opts.close_callback }:show()
end)
local Verification = require("source.zhihu.verify")
local route = Ext.list("web.routes")[1]
Assert.eq(route.name, "zhihu_verify")
Assert.eq(route.assets[1], "zhihu_verify.html")
Assert.is_true(route.public.config)
Assert.is_true(route.public.verify)

local status, response, headers
local function request(action, ticket, result, method)
    route.handle(method or "POST", action, { ticket = ticket, result = result }, function(code, body, extra)
        status, response, headers = code, body, extra
    end)
end
local finished, finish_err
local original = { jar = { _xsrf = "device-only", d_c0 = "device-only" }, token = "qr" }
local function newSession()
    finished, finish_err = nil, nil
    return Verification.new(original, function(ok, err) finished, finish_err = ok, err end)
end
local scripts = { "https://cstaticdun.126.net/load.min.js",
    "https://captcha.zhihu.com/api/v1/captcha/js?sessionId=fixture" }
local function configure(ticket)
    request("config", ticket)
    config_done({ scripts = scripts, session_id = "fixture" })
end

local session = newSession()
local ticket = path:match("#(.+)$")
Assert.matches(path, "^/zhihu_verify%.html#%x+$")
request("config", "wrong")
Assert.eq(status, 403)
request("config", ticket, nil, "GET")
Assert.eq(status, 405)
request("unknown", ticket)
Assert.eq(status, 404)
request("verify", ticket, "{}")
Assert.eq(status, 400, "还没加载挑战不能提交")
request("config", ticket)
Assert.eq(received_session, original)
request("config", ticket)
Assert.eq(status, 409)
config_done(nil, "network failed")
Assert.eq(status, 400)
Assert.eq(response.error, "network failed")
Assert.is_nil(finished)
configure(ticket)
Assert.eq(status, 200)
Assert.eq(response.title, "知乎安全验证")
Assert.eq(response.scripts, scripts)
Assert.is_nil(response.cookie, "Cookie 不发送到验证页面")
Assert.is_nil(response.jar)
Assert.is_nil(response.session_id, "提交时由设备决定挑战标识")
Assert.eq(headers[1], "Cache-Control: no-store")
request("verify", ticket, {})
Assert.eq(status, 400)
request("verify", ticket, string.rep("a", 16385))
Assert.eq(status, 400)
request("verify", ticket, '{"validate":"proof"}')
Assert.eq(received_session, original)
Assert.eq(received_id, "fixture")
Assert.eq(received_result, '{"validate":"proof"}')
request("config", ticket)
Assert.eq(status, 409)
verify_done(false, "not accepted")
Assert.eq(status, 400)
Assert.eq(response.error, "not accepted")
Assert.is_nil(finished)
request("verify", ticket, '{"validate":"retry"}')
verify_done(true)
Assert.eq(status, 200)
Assert.is_true(finished)
Assert.is_nil(finish_err)
Assert.is_true(session.dialog.closed)
Assert.is_nil(next(timers))
request("verify", ticket, "{}")
Assert.eq(status, 403, "成功票据不可重放")

session = newSession()
ticket = path:match("#(.+)$")
request("config", ticket)
session.dialog:close()
Assert.is_false(finished)
Assert.eq(finish_err, "验证已取消")
Assert.is_true(config_cancelled)
config_done({ scripts = scripts, session_id = "late" })
Assert.eq(status, 403)
Assert.is_false(finished)

session = newSession()
ticket = path:match("#(.+)$")
configure(ticket)
request("verify", ticket, "{}")
session:cancel()
Assert.is_true(verify_cancelled)
verify_done(true)
Assert.eq(status, 403)
Assert.is_nil(finished, "主动取消不接受迟到回调")

session = newSession()
ticket = path:match("#(.+)$")
session.timeout()
Assert.is_false(finished)
Assert.eq(finish_err, "验证已过期，请重新发起验证")
request("config", ticket)
Assert.eq(status, 403)

session = newSession()
ticket = path:match("#(.+)$")
request("config", ticket)
session.expires = os.time() - 1
config_done({ scripts = scripts, session_id = "expired" })
Assert.eq(status, 403)
Assert.is_false(finished)

Ext.reset()
session = newSession()
Assert.is_true(session.done)
Assert.is_false(finished)
Assert.eq(finish_err, "无法打开远程验证，请先连接 Wi-Fi 并启用远程管理功能")
Assert.is_nil(next(timers))
