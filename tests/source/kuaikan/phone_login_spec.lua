--[[--
快看手机号输入：官方格式、协议确认、密码原值、短信候选会话和取消。

@module tests.source.kuaikan.phone_login_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field
local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
local connected, cancelled, proof_submit, proof_done, proof_session = true, 0, nil, nil, nil
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
local sessions = {}
package.loaded["source.kuaikan.login"] = {
    new = function()
        local session = {}
        function session:cancel() cancelled = cancelled + 1 end
        function session:passwordAsync(phone, password, proof, cb)
            self.phone, self.password, self.proof, self.pending = phone, password, proof, cb
        end
        function session:sendCodeAsync(phone, proof, cb)
            self.phone, self.proof, self.pending = phone, proof, cb
        end
        function session:codeAsync(phone, code, cb)
            self.phone, self.code, self.pending = phone, code, cb
        end
        sessions[#sessions + 1] = session
        return session
    end,
}
package.loaded["source.kuaikan.verify"] = {
    new = function(session, submit, cb)
        proof_session, proof_submit, proof_done = session, submit, cb
        return { cancel = function() cancelled = cancelled + 1 end }
    end,
}
local Phone = require("source.kuaikan.phone_login")
local logged = 0
local function on_user() logged = logged + 1 end
local window = Phone.new("password", on_user)
window:start()
local input = Themed.last("input")
Assert.eq(input.title, "快看密码登录")
Assert.eq(input.fields[3].text_type, "password")
input.callback("+86", "13800000000", "")
Assert.eq(Themed.last("toast").text, "请输入密码")
input.callback("+86", "13800000000", " pass测试 ")
Assert.matches(Themed.last("confirm").text, "https://www%.kuaikanmanhua%.com/webs/agreement")
Themed.last("confirm").ok_callback()
Assert.is_true(input.closed)
Assert.eq(proof_session, window.session)
Assert.is_true(window.busy)
proof_submit({ ticket = "proof", random = "random" }, function() end)
Assert.eq(window.session.password, " pass测试 ")
Assert.eq(window.session.phone, "+86-13800000000")
proof_done(nil, "password refused")
Assert.eq(Themed.last("toast").text, "password refused")
Assert.is_nil(Themed.last("input").fields[3].text)
Assert.is_false(window.busy)
Themed.last("input").callback("+86", "13800000000", "new")
window:cancel()
proof_done({ user_id = "7" })
Assert.eq(logged, 0)

window = Phone.new("sms", on_user)
window:start()
input = Themed.last("input")
Assert.eq(input.title, "快看短信登录")
input.callback("+86", "13800000000", "123456")
Assert.matches(Themed.last("toast").text, "请先获取")
connected = false
input.actions[1].callback("+86", "13800000000")
Assert.eq(Themed.last("toast").text, "网络不可用，请先连接 Wi-Fi")
connected = true
input.actions[1].callback("+86", "123")
Assert.eq(Themed.last("toast").text, "请输入有效的手机号和国际区号")
input.actions[1].callback("+86", "13800000000")
Themed.last("confirm").ok_callback()
proof_submit({ ticket = "proof", random = "random" }, function() end)
Assert.eq(window.session.phone, "+86-13800000000")
window.session.sms_phone, window.session.sms_retry_at = "+86-13800000000", os.time() + 60
proof_done(true)
Assert.eq(Themed.last("toast").text, "验证码已发送")
input = Themed.last("input")
Assert.eq(input.fields[2].text, "13800000000")
input.actions[1].callback("+86", "13800000000")
Assert.eq(Themed.last("toast").text, "请稍后再获取验证码")
input.callback("+86", "13900000000", "123456")
Assert.matches(Themed.last("toast").text, "请先获取")
input.callback("+86", "13800000000", " 123456 ")
Assert.eq(window.session.code, "123456")
Assert.is_true(window.busy)
window.session.pending({ user_id = "7" })
Assert.eq(logged, 1)
Assert.is_true(input.closed)
Assert.is_true(cancelled > 0)

window = Phone.new("sms", on_user)
window:start()
window.session.sms_phone = "+86-13800000000"
input = Themed.last("input")
input.callback("+86", "13800000000", "123456")
local pending = window.session.pending
input:close()
pending({ user_id = "7" })
Assert.eq(logged, 1)
Assert.is_nil(window.dialog)
Assert.is_false(window.busy)
input.actions[1].callback("+86", "13800000000")
Assert.is_nil(window.verification)
