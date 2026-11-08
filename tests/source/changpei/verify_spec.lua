--[[--
长佩滑块验证会话：票据隔离、错误重试、取消与过期。

@module tests.source.changpei.verify_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
local Ext = require("utils.extension")
Ext.reset()
local cookie = "device-session"
local submit, submit_cancelled, submitted_token
package.preload["l10n"] = function()
    return { apply = function() end, get = function() return require("gettext") end }
end
package.preload["source.changpei.client"] = function()
    return {
        cookie = function() return cookie end,
        readCheckAsync = function(token, cb)
            submitted_token, submit = token, cb
            return { cancel = function() submit_cancelled = true end }
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
local Verification = require("source.changpei.verify")
local route = Ext.list("web.routes")[1]
local status, response, headers
local function request(action, params, method)
    route.handle(method or "POST", action, params, function(code, body, extra)
        status, response, headers = code, body, extra
    end)
end
local finished, finish_err
local function newSession()
    return Verification.new(function(ok, err) finished, finish_err = ok, err end)
end
local function send(ticket_value, code)
    request("verify", { ticket = ticket_value, token = code })
end
local session = newSession()
local ticket = path:match("#(.+)$")
Assert.matches(path, "^/changpei_verify%.html#%x+$")
request("config", { ticket = ticket })
Assert.eq(status, 200)
Assert.eq(response.title, "长佩滑块验证")
Assert.is_nil(response.cookie, "配置不得泄露设备 Cookie")
Assert.eq(headers[1], "Cache-Control: no-store")
request("config", { ticket = "wrong" })
Assert.eq(status, 403)
request("verify", { ticket = ticket, token = {} })
Assert.eq(status, 400)
request("verify", { ticket = ticket, token = string.rep("a", 16385) })
Assert.eq(status, 400)
request("verify", { ticket = ticket, token = "proof" }, "GET")
Assert.eq(status, 405)
request("unknown", { ticket = ticket })
Assert.eq(status, 404)

send(ticket, "proof")
Assert.eq(submitted_token, "proof")
send(ticket, "another")
Assert.eq(status, 409, "同一会话不能并发提交滑块")
submit(false, "server rejected")
Assert.eq(status, 400)
Assert.eq(response.error, "server rejected")
Assert.is_nil(finished, "验证失败保留二维码让用户重试")
send(ticket, "retry-proof")
submit(true)
Assert.eq(status, 200)
Assert.is_true(finished)
Assert.is_nil(finish_err)
Assert.is_true(session.dialog.closed)
Assert.is_nil(next(timers))
send(ticket, "replay")
Assert.eq(status, 403, "成功票据不可重放")

finished = nil
session = newSession()
ticket = path:match("#(.+)$")
send(ticket, "pending-proof")
session.dialog:close()
Assert.is_false(finished)
Assert.eq(finish_err, "验证已取消")
Assert.is_true(submit_cancelled)
submit(true)
Assert.is_false(finished, "关窗后不接受迟到的验证成功")
Assert.eq(status, 403)

session = newSession()
ticket = path:match("#(.+)$")
session.timeout()
Assert.eq(finish_err, "验证已过期，请重新发起验证")
request("config", { ticket = ticket })
Assert.eq(status, 403)

session = newSession()
ticket = path:match("#(.+)$")
cookie = "another-account"
send(ticket, "proof")
Assert.eq(status, 403, "不能拿旧二维码给新账号提交验证")
session:cancel()
Assert.is_nil(next(timers))

finished = nil
session = newSession()
ticket = path:match("#(.+)$")
send(ticket, "pending")
cookie = "changed-during-request"
submit(true)
Assert.eq(status, 403)
Assert.is_false(finished, "请求中换账号，旧验证成功也不能继续开书")

session = newSession()
ticket = path:match("#(.+)$")
session.expires = os.time() - 1
request("config", { ticket = ticket })
Assert.eq(status, 403, "主循环未跑过期定时器也不能用过期票据")
session:cancel()

Ext.reset()
finished = nil
session = newSession()
Assert.is_false(finished, "远程管理未启用时立即失败，不留下悬挂回调")
Assert.eq(finish_err, "无法打开远程验证，请先连接 Wi-Fi 并启用远程管理功能")
Assert.is_true(session.done)
Assert.is_nil(next(timers))
