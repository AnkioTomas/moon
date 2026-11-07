--[[--
扫码同步回调不会覆盖在飞句柄，关闭后忽略迟到结果。

@module tests.source.tadu.qrlogin_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local poll, exchange, stopped, signed_in
package.loaded["source.tadu.client"] = {
    qrCreateAsync = function(cb)
        cb("uuid")
        return { cancel = function() error("cancelled completed QR request") end }
    end,
    qrPollAsync = function(_uuid, _last, cb)
        poll = cb
        return { cancel = function() stopped = "poll" end }
    end,
    exchangeAsync = function(_code, cb)
        exchange = cb
        return { cancel = function() stopped = "exchange" end }
    end,
}
package.loaded["ui.themes.widgets.qr"] = {
    new = function(_class, spec)
        return { show = function() end, close = function() spec.close_callback() end }
    end,
}
local login = require("source.tadu.qrlogin"):new(function() signed_in = true end)
login:start()
login:cancel()
Assert.eq(stopped, "poll")
poll("ok", "code", 405)
Assert.is_nil(exchange)
login:start()
poll("ok", "code", 405)
login:cancel()
Assert.eq(stopped, "exchange")
exchange({ name = "测试" })
Assert.is_nil(signed_in)
