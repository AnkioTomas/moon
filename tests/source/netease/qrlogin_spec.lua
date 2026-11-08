--[[--
微信扫码等待、确认、拒绝、过期、网络失败与取消。

@module tests.source.netease.qrlogin_spec
--]]
---@diagnostic disable: undefined-field

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
local pending
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_self, _seconds, fn) pending = fn end,
    unschedule = function(_self, fn) if pending == fn then pending = nil end end,
}
local polls, cancelled, queue, create_callback, exchange_callback = 0, 0, {}, nil, nil
local defer_create, defer_exchange = false, false
package.loaded["source.netease.auth"] = {
    new = function()
        return {
            cancel = function() cancelled = cancelled + 1 end,
            qrCreateAsync = function(_self, cb)
                if defer_create then create_callback = cb else cb("uuid") end
            end,
            qrPollAsync = function(_self, uuid, last, cb)
                Assert.eq(uuid, "uuid")
                polls = polls + 1
                local result = table.remove(queue, 1)
                cb(result.status, result.code, result.err)
            end,
            exchangeAsync = function(_self, code, cb)
                Assert.eq(code, "wx-code")
                if defer_exchange then exchange_callback = cb else cb(true) end
            end,
        }
    end,
}
local QRLogin = require("source.netease.qrlogin")
local function start(results)
    polls, pending, queue = 0, nil, results
    local done = false
    local qr = QRLogin:new(function() done = true end)
    qr:start()
    return qr, function() return done end
end
local qr, done = start({ { status = 408 }, { status = 404 }, { status = 404 }, { status = 405, code = "wx-code" } })
Assert.eq(Themed.last("qr").text, "https://open.weixin.qq.com/connect/confirm?uuid=uuid")
Assert.is_false(done())
pending()
Assert.eq(Themed.last("toast").text, "已扫码，请在手机上确认")
local before = #Themed.all("toast")
pending()
Assert.len(Themed.all("toast"), before)
pending()
Assert.is_true(done())
Assert.is_true(Themed.last("qr").closed)
Assert.is_true(Themed.last("progress_dialog").closed)

qr, done = start({ { status = 408 } })
local late = pending
Themed.last("qr"):close()
Assert.is_nil(pending)
late()
Assert.eq(polls, 1)
Assert.is_false(done())
for _idx, result in ipairs({
    { status = 403, message = "已在微信中拒绝登录" },
    { status = 402, message = "二维码已过期" },
    { err = "network down", message = "network down" },
}) do
    qr, done = start({ result })
    Assert.eq(Themed.last("confirm").text, result.message)
    Assert.is_false(done())
end
qr, done = start({ { status = 408 } })
qr.deadline = 0
pending()
Assert.eq(Themed.last("confirm").text, "二维码已过期")
Assert.eq(polls, 1)
defer_create = true
qr, done = start({})
Themed.last("progress_dialog").on_cancel()
before = #Themed.all("qr")
create_callback("late")
Assert.len(Themed.all("qr"), before)
Assert.is_false(done())
defer_create, defer_exchange = false, true
qr, done = start({ { status = 405, code = "wx-code" } })
qr:cancel()
exchange_callback(true)
Assert.is_false(done(), "关窗后不能接受迟到的授权")
Assert.is_true(cancelled > 0)
