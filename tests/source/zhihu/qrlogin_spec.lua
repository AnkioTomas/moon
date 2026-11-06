--[[--
知乎扫码弹窗：等待手机确认、刷新、失败重试与取消在途请求。

@module tests.source.zhihu.qrlogin_spec
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

local polls, queue = 0, {}
local defer_create, create_callback, create_cancelled
local defer_poll, poll_callback, poll_cancelled
local create_error, expires_at, create_challenge, resumed
package.loaded["source.zhihu.client"] = {
    qrCreateAsync = function(cb, session)
        resumed = session
        if defer_create then
            create_callback = cb
            return { cancel = function() create_cancelled = true end }
        end
        cb(not create_error and not create_challenge and {
            token = "tok", link = "https://www.zhihu.com/account/scan", expires_at = expires_at,
        } or nil, create_error, create_challenge)
        return { cancel = function() end }
    end,
    qrPollAsync = function(session, cb)
        polls = polls + 1
        Assert.is_true(type(session.token) == "string")
        if defer_poll then
            poll_callback = cb
            return { cancel = function() poll_cancelled = true end }
        end
        local result = table.remove(queue, 1)
        cb(result.kind, result.extra, result.err)
        return { cancel = function() end }
    end,
}
package.loaded["source.zhihu.qrlogin"] = nil
local QRLogin = require("source.zhihu.qrlogin")

local function start(results)
    queue, polls, pending = results, 0, nil
    local done
    local qr = QRLogin:new(function() done = true end)
    qr:start()
    return qr, function() return done end
end

local qr, done = start({ { kind = "ok" } })
Assert.is_true(done())
Assert.eq(Themed.last("qr").text, "https://www.zhihu.com/account/scan")
Assert.eq(Themed.last("qr").title, "知乎扫码登录")
Assert.eq(Themed.last("qr").caption, "用知乎 App 扫一扫")
Assert.is_true(Themed.last("qr").closed)
Assert.is_true(Themed.last("progress_dialog").closed)
Assert.eq(polls, 1)

qr, done = start({
    { kind = "refresh", extra = { token = "tok2", link = "https://www.zhihu.com/account/scan/2" } },
    { kind = "ok" },
})
Assert.is_nil(done(), "换码不能同步递归轮询")
Assert.eq(Themed.last("qr").text, "https://www.zhihu.com/account/scan/2")
pending()
Assert.is_true(done())
Assert.eq(polls, 2)

qr, done = start({ { kind = "scanned" }, { kind = "scanned" }, { kind = "ok" } })
Assert.eq(Themed.last("toast").text, "已扫码，请在手机上确认")
Assert.is_nil(done())
local count = #Themed.all("toast")
pending()
Assert.eq(#Themed.all("toast"), count, "等待确认只提示一次")
pending()
Assert.is_true(done())

qr, done = start({ { kind = "wait" } })
local queued = pending
Themed.last("qr"):close()
Assert.is_nil(pending)
queued()
Assert.eq(polls, 1, "关闭二维码后不再轮询")
Assert.eq(Themed.last("toast").text, "已取消登录")
Assert.is_nil(done())

qr, done = start({ { err = "网络环境异常" } })
Assert.eq(Themed.last("confirm").text, "网络环境异常")
Assert.eq(Themed.last("confirm").ok_text, "重新获取")
Assert.is_true(Themed.last("qr").closed)
queue = { { kind = "ok" } }
Themed.last("confirm").ok_callback()
Assert.is_true(done())

qr, done = start({ { kind = "expired" } })
Assert.eq(Themed.last("confirm").text, "二维码已过期")
Assert.is_nil(done())
expires_at = os.time() - 1
qr, done = start({})
Assert.eq(polls, 0, "已过期的码不再轮询")
Assert.eq(Themed.last("confirm").text, "二维码已过期")
expires_at = nil

create_error = "offline"
qr, done = start({})
Assert.eq(Themed.last("confirm").text, "offline")
Assert.is_true(Themed.last("progress_dialog").closed)
create_error = nil

defer_poll = true
qr, done = start({})
qr:cancel()
Assert.is_true(poll_cancelled, "同步出码回调不能覆盖在途轮询句柄")
Assert.is_true(Themed.last("qr").closed)
poll_callback("ok")
Assert.is_nil(done())
defer_poll = false

local verification_callback, verification_cancelled, verified_session
package.loaded["source.zhihu.verify"] = {
    new = function(session, cb)
        verified_session, verification_callback = session, cb
        return { cancel = function() verification_cancelled = true end }
    end,
}
local challenge = { jar = {}, token = "old" }
qr, done = start({ { kind = "verify", extra = challenge } })
Assert.eq(verified_session, challenge)
Assert.is_true(Themed.last("qr").closed)
Assert.is_nil(done(), "安全验证通过之前不能认为登录成功")
queue = { { kind = "ok" } }
verification_callback(true)
Assert.eq(resumed, challenge, "验证后必须沿用原匿名会话重新出码")
Assert.is_true(done())

create_challenge = challenge
qr, done = start({})
Assert.eq(verified_session, challenge, "出码前被拦截也能进入验证")
create_challenge = nil
qr:cancel()
Assert.is_true(verification_cancelled)
local before = #Themed.all("qr")
verification_callback(true)
Assert.eq(#Themed.all("qr"), before, "取消验证后不接受迟到回调")
Assert.is_nil(done())

defer_create = true
qr, done = start({})
Assert.eq(Themed.last("progress_dialog").text, "正在获取二维码…")
Themed.last("progress_dialog").on_cancel()
Assert.is_true(create_cancelled)
Assert.is_true(Themed.last("progress_dialog").closed)
local shown = #Themed.all("qr")
create_callback({ token = "late", link = "https://www.zhihu.com/late" })
Assert.eq(#Themed.all("qr"), shown, "取消出码后不弹迟到的二维码")
Assert.is_nil(done())
