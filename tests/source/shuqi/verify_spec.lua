--[[--
书旗滑块票据隔离、取消与离线登录入口。

@module tests.source.shuqi.verify_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
local route, sends = nil, {}
package.loaded["utils.extension"] = {
    add = function(_point, provider) route = provider end,
    call = function(_point, _path, _title, _text, options)
        return { close = function() options.close_callback() end }
    end,
}
package.loaded["ui/uimanager"] = { scheduleIn = function() end, unschedule = function() end }
package.loaded["source.shuqi.client"] = {
    sendCodeAsync = function(phone, captcha, cb, browser)
        local send = { phone = phone, captcha = captcha, cb = cb, browser = browser }
        sends[#sends + 1] = send
        return { cancel = function() send.cancelled = true end }
    end,
}
local Verification = require("source.shuqi.verify")
local finished = 0
local first = Verification.new("13800138000", function() finished = finished + 1 end)
local second = Verification.new("13900139000", function() finished = finished + 1 end)
local status, body
local function reply(code, response) status, body = code, response end
route.handle("POST", "config", { ticket = first.ticket }, reply)
Assert.matches(body.load_error, "可能被广告拦截插件")
Assert.matches(body.load_timeout, "超时")
Assert.matches(body.load_timeout, "可能被广告拦截插件")
route.handle("POST", "verify", { ticket = first.ticket, captcha = "one", fingerprint = "first", user_agent = "Test-UA" }, reply)
route.handle("POST", "verify", { ticket = second.ticket, captcha = "two", user_agent = "bad\r\nheader" }, reply)
Assert.eq(status, 400)
Assert.len(sends, 1)
route.handle("POST", "verify", { ticket = second.ticket, captcha = "two", fingerprint = "second" }, reply)
sends[2].cb(true)
sends[1].cb(true)
Assert.eq(first.browser.fingerprint, "first")
Assert.eq(first.browser.user_agent, "Test-UA")
Assert.eq(sends[1].browser.user_agent, "Test-UA")
Assert.eq(second.browser.fingerprint, "second")
Assert.eq(finished, 2)
route.handle("POST", "verify", { ticket = first.ticket, captcha = "replay" }, reply)
Assert.eq(status, 403)
local cancelled = Verification.new("13800138000", function() finished = finished + 1 end)
route.handle("POST", "verify", { ticket = cancelled.ticket, captcha = "three" }, reply)
cancelled:cancel()
Assert.is_true(sends[3].cancelled)
sends[3].cb(true)
Assert.is_nil(cancelled.browser)
Assert.eq(finished, 2)
Assert.eq(status, 403)
package.loaded["ui/network/manager"] = { isConnected = function() return false end }
require("source.shuqi.setting").login()
Assert.is_nil(Themed.last("input"))
Assert.eq(Themed.last("toast").text, "网络不可用，请先连接 Wi-Fi")
