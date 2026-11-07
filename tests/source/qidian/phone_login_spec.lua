--[[-- 起点短信窗口：同意协议、断网、冷却、绑定手机号与取消。 @module tests.source.qidian.phone_login_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Theme = require("support.theme_stubs")
Theme.install()
local connected, begins, sends, verifies, cancelled, deferred, late = true, 0, 0, 0, 0, false, nil
package.preload["ui/network/manager"] = function() return { isConnected = function() return connected end } end
package.preload["source.qidian.login"] = function()
    return { new = function() return {
        beginAsync = function(self, cb) begins = begins + 1; self.initialized = true; cb({}) end,
        sendCodeAsync = function(_self, country, phone, proof, cb)
            sends = sends + 1
            Assert.eq(country, "+86"); Assert.eq(phone, "13800000000"); Assert.is_nil(proof)
            cb({ nextAction = 0 })
        end,
        verifyAsync = function(_self, phone, code, cb)
            verifies = verifies + 1
            Assert.eq(phone, "13800000000"); Assert.eq(code, "123456")
            if deferred then late = function() cb("candidate") end else cb("candidate") end
        end,
        cancel = function() cancelled = cancelled + 1 end,
    } end }
end
local Phone = require("source.qidian.phone_login")
local cookie
local phone = Phone.new(function(value) cookie = value end)
phone:start()
Assert.eq(Theme.last("input").title, "起点手机号验证码登录")
Assert.is_true(Theme.last("input").keep_open)

connected = false
phone:send("+86", "13800000000")
Assert.eq(sends, 0)
Assert.matches(Theme.last("toast").text, "网络不可用")
connected = true
phone:send("+86", "invalid")
Assert.eq(sends, 0)
phone:send("+86", "13800000000")
Assert.eq(begins, 0, "同意协议前不初始化或发送短信")
Theme.last("confirm").ok_callback()
Assert.eq(begins, 1)
Assert.eq(sends, 1)
phone:send("+86", "13800000000")
Assert.eq(sends, 1, "冷却期不重复发短信")
phone:verify("+86", "13900000000", "123456")
Assert.eq(verifies, 0, "不能把验证码用于另一个手机号")
phone:verify("+86", "13800000000", "abc")
Assert.eq(verifies, 0)
phone:verify("+86", "13800000000", "123456")
Assert.eq(cookie, "candidate")
Assert.is_true(Theme.last("input").closed)
Assert.eq(cancelled, 1)

phone = Phone.new(function() Assert.is_true(false, "取消后不得保存迟到候选") end)
phone:start()
phone.agreed = true
phone:send("+86", "13800000000")
deferred = true
phone:verify("+86", "13800000000", "123456")
phone:cancel()
late()
Assert.eq(cancelled, 2)
Assert.is_nil(phone.phone)
