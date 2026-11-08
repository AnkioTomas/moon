--[[-- 起点验证码桥：仅 proof、时效、取消和候选会话存活。 @module tests.source.qidian.verify_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Ext = require("utils.extension")
local seq, interrupted = 0, 0
package.preload["utils.random"] = function() return { hex = function() seq = seq + 1; return "ticket" .. seq end } end
package.preload["ui/uimanager"] = function() return { scheduleIn = function() end, unschedule = function() end } end
package.preload["ui.guard"] = function() return { wrap = function(_label, fn) return fn end } end
Ext.add("web.open_page", function(path, _title, _text, opts)
    Assert.matches(path, "^/qidian_verify%.html#ticket")
    return { close = function() opts.close_callback() end }
end)
local Verification = require("source.qidian.verify")
local route
for _idx, item in ipairs(Ext.list("web.routes")) do if item.name == "qidian_verify" then route = item end end
local session = {
    interrupt = function() interrupted = interrupted + 1 end,
    imageAsync = function(_self, _url, cb) cb("data:image/png;base64,example") end,
}
local challenge = { nextAction = 11, imgSrc = "https://turing.captcha.qcloud.com/TCaptcha.js?aid=1600000770" }
local submitted, finished, late = nil, false, nil
local verification = Verification.new(session, challenge, function(proof, cb)
    submitted, late = proof, cb
end, function(data) finished = data ~= nil end)
local function request(action, fields, method)
    fields = fields or {}
    fields.ticket = fields.ticket or verification.ticket
    local status, data, headers
    route.handle(method or "POST", action, fields, function(code, body, extra) status, data, headers = code, body, extra end)
    return status, data, headers
end

Assert.eq((request("config", nil, "GET")), 405)
local status, data, headers = request("config")
Assert.eq(status, 200)
Assert.eq(data.appid, "1600000770")
Assert.eq(headers[1], "Cache-Control: no-store")
Assert.is_nil(data.phone)
Assert.is_nil(data.cookie)
Assert.eq((request("verify", { captcha_ticket = "trerror_invalid", randstr = "random" })), 400)
Assert.is_nil(submitted)
request("verify", { captcha_ticket = "proof", randstr = "random" })
Assert.eq(submitted, "random;proof", "顺序与官方 randstr + 分号 + ticket 一致")
Assert.eq((request("verify", { captcha_ticket = "proof", randstr = "random" })), 409)
late({ nextAction = 0 })
Assert.is_true(finished)
Assert.eq(interrupted, 0, "成功后候选会话必须继续用于短信提交")
Assert.eq((request("config")), 403, "验证票据用完即撤销")

verification = Verification.new(session, challenge, function(_proof, cb) late = cb end, function() end)
request("verify", { captcha_ticket = "proof", randstr = "random" })
verification:cancel()
late({ nextAction = 0 })
Assert.eq(interrupted, 1)
Assert.eq((request("config")), 403)

verification = Verification.new(session, { nextAction = 8, imgSrc = "/image" },
    function(proof, cb) Assert.eq(proof, "abcd"); cb({ nextAction = 0 }) end, function() end)
status, data = request("config")
Assert.eq(status, 200)
Assert.eq(data.mode, "image")
Assert.matches(data.image, "^data:image/png;")
Assert.eq((request("verify", { code = "abcd" })), 200)

verification = Verification.new(session, challenge, function() end, function() end)
verification.expires = os.time() - 1
Assert.eq((request("verify", { captcha_ticket = "proof", randstr = "random" })), 403)
verification:cancel()
