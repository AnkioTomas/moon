--[[--
豆瓣扫码窗口：同步前段回调不能覆盖在途句柄，关闭后不再登录。

@module tests.source.douban.qrlogin_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
local pending, session, calls = nil, nil, 0
package.preload["source.douban.client"] = function()
    return {
        newLogin = function()
            session = {
                cancel = function(self) self.cancelled = true end,
                beginQrAsync = function(_self, cb)
                    cb({ qr = "https://accounts.arkread.com/oidc/qrcode/confirm?code=test", code = "test",
                        authorize = "https://accounts.arkread.com/oauth2/authorize", expires_in = 300 })
                    return { cancel = function() end }
                end,
                qrStatusAsync = function(_self, code, cb)
                    Assert.eq(code, "test")
                    pending = { callback = cb }
                    return { cancel = function() pending.cancelled = true end }
                end,
                finishQrAsync = function(_self, _authorize, cb)
                    cb({ id = "test", name = "测试" })
                    return { cancel = function() end }
                end,
            }
            return session
        end,
    }
end
local QRLogin = require("source.douban.qrlogin")
local login = QRLogin:new(function() calls = calls + 1 end)
login:start()
local dialog = Themed.last("qr")
Assert.is_true(dialog.shown)
dialog:close()
Assert.is_true(pending.cancelled)
Assert.is_true(session.cancelled)
pending.callback("ok")
Assert.eq(calls, 0)

login:start()
dialog = Themed.last("qr")
pending.callback("ok")
Assert.eq(calls, 1)
Assert.is_true(dialog.closed)
Assert.eq(#Themed.all("toast"), 1)

login:start()
pending.callback(nil, "network failed")
Assert.eq(Themed.last("confirm").text, "network failed")
Assert.is_true(Themed.last("qr").closed)
Assert.eq(calls, 1)
