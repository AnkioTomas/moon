--[[--
得到扫码：候选会话归窗口所有，取消停掉当前轮询，校验后才完成登录。

@module tests.source.dedao.qrlogin_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local poll, candidate, stopped, signed_in, toast
local statuses = { 0, 1 }

package.preload["source.dedao.client"] = function()
    return {
        accessTokenAsync = function(done, jar)
            candidate = jar
            Assert.is_nil(jar.session)
            done("oauth")
            return { cancel = function() error("cancelled completed bootstrap") end }
        end,
        qrCreateAsync = function(_oauth, done, jar)
            Assert.eq(jar, candidate)
            done("qr")
            return { cancel = function() error("cancelled completed QR request") end }
        end,
        qrPollAsync = function(_oauth, _code, done, jar)
            Assert.eq(jar, candidate)
            poll = done
            return { cancel = function() stopped = true end }
        end,
        confirmLoginAsync = function(jar, done)
            Assert.eq(jar, candidate)
            done(true)
            return { cancel = function() error("cancelled completed account verification") end }
        end,
    }
end
package.preload["source.dedao.mapper"] = function()
    return {
        qrText = function() return "https://example.test/qr" end,
        login = function(wire) return wire.data.status == 1 and "ok" or "wait" end,
    }
end
package.preload["ui.themes.widgets.qr"] = function()
    return { new = function(_class, opts)
        return { show = function() end, close = function() opts.close_callback() end }
    end }
end
package.preload["ui.themes.widgets.toast"] = function()
    return { new = function(_class, opts) toast = opts.text; return { show = function() end } end }
end

local QRLogin = require("source.dedao.qrlogin")
local login = QRLogin:new(function() signed_in = true end)
login:start()
login:cancel()
Assert.is_true(stopped)
poll({ data = { status = statuses[2] } })
Assert.is_nil(signed_in)

stopped = false
login:start()
poll({ data = { status = statuses[2] } })
Assert.is_true(signed_in)
Assert.is_nil(toast)
Assert.is_nil(login.dialog)
