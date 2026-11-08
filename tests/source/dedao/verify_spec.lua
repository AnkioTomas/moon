--[[--
得到滑块绑定候选会话：只交 validate，不泄露凭证，成功发短信才完成。

@module tests.source.dedao.verify_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Theme = require("support.theme_stubs")
Theme.install()
local Ext = require("utils.extension")
Ext.reset()
local submit, sent_session, proof, cancelled
package.preload["source.dedao.client"] = function()
    return { sendSessionCodeAsync = function(session, captcha, done)
        sent_session, proof, submit = session, captcha, done
        return { cancel = function() cancelled = true end }
    end }
end
local timers = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_ui, _delay, fn) timers[fn] = true end,
        unschedule = function(_ui, fn) timers[fn] = nil end,
    }
end
package.preload["ui.guard"] = function() return { wrap = function(_label, fn) return fn end } end
local path
Ext.add("web.open_page", function(url, _title, _text, opts)
    path = url
    return require("ui.themes.widgets.qr"):new{ close_callback = opts.close_callback }:show()
end)
local Verification = require("source.dedao.verify")
local route = Ext.list("web.routes")[1]
local status, body, headers
local function request(action, params, method)
    route.handle(method or "POST", action, params, function(code, data, extra) status, body, headers = code, data, extra end)
end
local login = { phone = "13800000000", oauth = "private-oauth", jar = { session = "private-cookie" } }
local completed, err
local function start()
    completed, err = nil, nil
    return Verification.new({ session = login, captcha_id = "official-id" }, function(value, reason) completed, err = value, reason end)
end
local verification = start()
local ticket = path:match("#(.+)$")
request("config", { ticket = ticket })
Assert.eq(status, 200)
Assert.eq(body.captcha_id, "official-id")
Assert.is_nil(body.phone)
Assert.is_nil(body.oauth)
Assert.is_nil(body.jar)
Assert.eq(headers[1], "Cache-Control: no-store")
request("verify", { ticket = "invalid", validate = "proof" })
Assert.eq(status, 403)
request("verify", { ticket = ticket, validate = {} })
Assert.eq(status, 400)
request("verify", { ticket = ticket, validate = string.rep("a", 16385) })
Assert.eq(status, 400)
request("config", { ticket = ticket }, "GET")
Assert.eq(status, 405)
request("unknown", { ticket = ticket })
Assert.eq(status, 404)
request("verify", { ticket = ticket, validate = "proof", captcha_id = "browser-id", phone = "other-phone" })
Assert.eq(sent_session, login)
Assert.eq(proof.captchaId, "official-id")
Assert.eq(proof.validate, "proof")
request("verify", { ticket = ticket, validate = "duplicate" })
Assert.eq(status, 409)
submit(nil, "SMS refused", "new-official-id")
Assert.eq(status, 400)
Assert.is_nil(completed)
request("config", { ticket = ticket })
Assert.eq(body.captcha_id, "new-official-id")
request("verify", { ticket = ticket, validate = "retry" })
submit(true)
Assert.eq(status, 200)
Assert.eq(completed, login)
Assert.is_true(verification.dialog == nil)
Assert.is_nil(next(timers))
request("verify", { ticket = ticket, validate = "replay" })
Assert.eq(status, 403)

verification = start()
ticket = path:match("#(.+)$")
request("verify", { ticket = ticket, validate = "pending" })
verification.dialog:close()
Assert.eq(err, "验证已取消")
Assert.is_true(cancelled)
submit(true)
Assert.eq(status, 403)
Assert.is_nil(completed)

verification = start()
ticket = path:match("#(.+)$")
verification.expires = os.time() - 1
request("config", { ticket = ticket })
Assert.eq(status, 403)
verification.timeout()
Assert.eq(err, "验证已过期，请重新发起验证")
Assert.is_nil(next(timers))
