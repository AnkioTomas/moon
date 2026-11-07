--[[--
快看远程滑块：临时票据、敏感字段隔离、取消、拒绝应急票据与重复提交。

@module tests.source.kuaikan.verify_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field
local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
local Ext = require("utils.extension")
Ext.reset()
local timers = {}
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_ui, _delay, fn) timers[fn] = true end,
    unschedule = function(_ui, fn) timers[fn] = nil end,
}
local path
Ext.add("web.open_page", function(url, _title, _text, opts)
    path = url
    return require("ui.themes.widgets.qr"):new{ close_callback = opts.close_callback }:show()
end)
local Verification = require("source.kuaikan.verify")
local route = Ext.list("web.routes")[1]
local status, body, headers, completed, reason, submitted, proof, cancels = nil, nil, nil, nil, nil, nil, nil, 0
local function request(action, params, method)
    route.handle(method or "POST", action, params, function(code, data, extra)
        status, body, headers = code, data, extra
    end)
end
local function start()
    completed, reason = nil, nil
    return Verification.new({ cancel = function() cancels = cancels + 1 end }, function(fields, cb)
        proof, submitted = fields, cb
    end, function(result, err) completed, reason = result, err end)
end
local verification = start()
local ticket = path:match("#(.+)$")
request("config", { ticket = ticket })
Assert.eq(status, 200)
Assert.eq(body.appid, "2034681882")
Assert.is_nil(body.phone)
Assert.is_nil(body.password)
Assert.is_nil(body.cookie)
Assert.eq(headers[1], "Cache-Control: no-store")
request("verify", { ticket = "invalid", captcha_ticket = "proof", randstr = "random" })
Assert.eq(status, 403)
for _idx, value in ipairs({ "", {}, "trerror_1001_x", string.rep("a", 4097) }) do
    request("verify", { ticket = ticket, captcha_ticket = value, randstr = "random" })
    Assert.eq(status, 400)
end
request("config", { ticket = ticket }, "GET")
Assert.eq(status, 405)
request("unknown", { ticket = ticket })
Assert.eq(status, 404)
request("verify", { ticket = ticket, captcha_ticket = "proof", randstr = "random", password = "ignored" })
Assert.eq(proof.ticket, "proof")
Assert.eq(proof.random, "random")
Assert.is_nil(proof.password)
request("verify", { ticket = ticket, captcha_ticket = "repeat", randstr = "random" })
Assert.eq(status, 409)
submitted({ user_id = "7" })
Assert.eq(status, 200)
Assert.is_true(body.ok)
Assert.is_nil(body.user_id)
Assert.eq(completed.user_id, "7")
Assert.is_nil(next(timers))
Assert.is_nil(verification.submit)
request("verify", { ticket = ticket, captcha_ticket = "replay", randstr = "random" })
Assert.eq(status, 403)

verification = start()
ticket = path:match("#(.+)$")
request("verify", { ticket = ticket, captcha_ticket = "proof", randstr = "random" })
submitted(nil, "private server detail")
Assert.eq(status, 400)
Assert.is_nil(body.error:find("private", 1, true))
Assert.eq(reason, "private server detail")
verification = start()
ticket = path:match("#(.+)$")
request("verify", { ticket = ticket, captcha_ticket = "proof", randstr = "random" })
verification.dialog:close()
submitted(true)
Assert.eq(status, 403)
Assert.is_nil(completed)
Assert.eq(reason, "验证已取消")
Assert.is_true(cancels > 0)
verification = start()
verification.expires = os.time() - 1
request("config", { ticket = verification.ticket })
Assert.eq(status, 403)
verification.timeout()
Assert.eq(reason, "验证已过期，请重新发起验证")
Assert.is_nil(next(timers))
