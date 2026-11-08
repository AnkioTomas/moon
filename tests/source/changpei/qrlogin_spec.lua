--[[-- 长佩二维码帧、网络错误与关闭后的迟到回调。 @module tests.source.changpei.qrlogin_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Theme = require("support.theme_stubs")
Theme.install()
local late, cancelled, sync = nil, false, true
local polling_timeout
package.preload["http.request"] = function()
    return {
        get = function(_url, _opts, cb)
            if sync then cb("", nil, {}) else late = cb end
            return { cancel = function() cancelled = true end }
        end,
        post = function(url, _body, opts, cb)
            if url:match("/qrcode_polling$") then polling_timeout = opts.timeout end
            late = cb
            return { cancel = function() cancelled = true end }
        end,
        headerAll = function() return { "PHPSESSID=anonymous; Path=/; HttpOnly" } end,
        header = function() return "0" end,
    }
end
local QR = require("source.changpei.qrlogin")
local value = ("a"):rep(200)
Assert.eq(QR.decode(QR.frame(value))[1], value, "refresh token 长度用 protobuf varint")
Assert.eq(QR.decode(QR.frame("ok") .. "\128\0\0\0\0")[1], "ok", "不把 gRPC trailer 当 protobuf")
Assert.is_nil(next(QR.decode("\0\0\0\0\9short")), "截断帧不是成功回包")

local called = false
local login = QR:new(function() called = true end)
login:start()
Assert.not_nil(late)
login:cancel()
Assert.is_true(cancelled, "同步匿名会话不能覆盖获取二维码的句柄")
late(QR.frame("token"), nil, {})
Assert.is_nil(Theme.last("qr"))
Assert.is_false(called)

login = QR:new(function() called = true end)
login:_poll(login.generation, "token", os.time())
Assert.is_true(polling_timeout > 30, "官网长轮询必须能等到约 30 秒的待扫码响应")
late(nil, "network unavailable", {})
Assert.eq(Theme.last("confirm").text, "network unavailable", "网络错误不冒充二维码过期")

sync, cancelled = false, false
login = QR:new(function() called = true end)
login:start()
login:cancel()
late("", nil, {})
Assert.is_true(cancelled)
Assert.is_false(called)
