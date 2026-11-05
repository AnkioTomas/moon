--[[--
七猫滑块仅提交 rid；手机号隔离、一次性票据、异步取消与过期。

@module tests.source.qimao.verify_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
local Ext = require("utils.extension")
Ext.reset()
local token
local submit, submitted_phone, submitted_rid, cancelled
package.preload["source.qimao.client"] = function()
    return {
        token = function() return token end,
        sendCodeAsync = function(phone, rid, cb)
            submitted_phone, submitted_rid, submit = phone, rid, cb
            return { cancel = function() cancelled = true end }
        end,
    }
end
local timers = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, fn) timers[fn] = true end,
        unschedule = function(_self, fn) timers[fn] = nil end,
    }
end
package.preload["ui.guard"] = function() return { wrap = function(_label, fn) return fn end } end
local path
Ext.add("web.open_page", function(url, _title, _text, opts)
    path = url
    return require("ui.themes.widgets.qr"):new{ close_callback = opts.close_callback }:show()
end)
local Verification = require("source.qimao.verify")
local route = Ext.list("web.routes")[1]
local status, response, headers
local function request(action, params, method)
    route.handle(method or "POST", action, params, function(code, body, extra)
        status, response, headers = code, body, extra
    end)
end
local finished, finish_err
local function newSession()
    finished, finish_err = nil, nil
    return Verification.new("13800000000", function(ok, err) finished, finish_err = ok, err end)
end
local session = newSession()
local ticket = path:match("#(.+)$")
Assert.matches(path, "^/qimao_verify%.html#%x+$")
request("config", { ticket = ticket })
Assert.eq(status, 200)
Assert.is_nil(response.phone, "网页不能读到设备手机号")
Assert.is_nil(response.token, "网页不能读到登录 token")
Assert.is_nil(response.fields, "不是远程账号 / 短信输入表单")
Assert.eq(headers[1], "Cache-Control: no-store")
request("verify", { ticket = "wrong", rid = "proof" })
Assert.eq(status, 403)
request("verify", { ticket = ticket, rid = {} })
Assert.eq(status, 400)
request("verify", { ticket = ticket, rid = string.rep("a", 1025) })
Assert.eq(status, 400)
request("config", { ticket = ticket }, "GET")
Assert.eq(status, 405)
request("other", { ticket = ticket })
Assert.eq(status, 404)

request("verify", { ticket = ticket, rid = "proof", phone = "another-phone", code = "browser-code" })
Assert.eq(submitted_phone, "13800000000", "浏览器不能换掉目标手机号")
Assert.eq(submitted_rid, "proof")
request("verify", { ticket = ticket, rid = "another-proof" })
Assert.eq(status, 409)
submit(false, "验证码发送频繁")
Assert.eq(status, 400)
Assert.eq(response.error, "验证码发送频繁")
Assert.is_nil(finished, "发短信失败不能报告验证成功")
request("verify", { ticket = ticket, rid = "retry-proof" })
submit(true)
Assert.eq(status, 200)
Assert.is_true(finished)
Assert.is_true(session.dialog.closed)
Assert.is_nil(next(timers))
request("verify", { ticket = ticket, rid = "replay" })
Assert.eq(status, 403, "一次验证只允许成功发送一次短信")

session = newSession()
ticket = path:match("#(.+)$")
request("verify", { ticket = ticket, rid = "pending" })
session.dialog:close()
Assert.is_false(finished)
Assert.eq(finish_err, "验证已取消")
Assert.is_true(cancelled)
submit(true)
Assert.eq(status, 403)
Assert.is_false(finished, "关窗后不能接收迟到的成功")

session = newSession()
ticket = path:match("#(.+)$")
session.expires = os.time() - 1
request("config", { ticket = ticket })
Assert.eq(status, 403)
session.timeout()
Assert.eq(finish_err, "验证已过期，请重新发起验证")
Assert.is_nil(next(timers))

session = newSession()
ticket = path:match("#(.+)$")
request("verify", { ticket = ticket, rid = "pending" })
token = "new-account"
submit(true)
Assert.eq(status, 403)
Assert.is_false(finished, "换账号后不能把旧手机号的验证报为成功")

Ext.reset()
session = newSession()
Assert.is_true(session.done)
Assert.is_false(finished)
Assert.eq(finish_err, "无法打开远程验证，请先连接 Wi-Fi 并启用远程管理功能")
Assert.is_nil(next(timers))
