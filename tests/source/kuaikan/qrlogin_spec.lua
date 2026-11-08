--[[--
快看扫码窗口：已扫码、确认、拒绝、超时、刷新和关闭。

@module tests.source.kuaikan.qrlogin_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Themed = require("support.theme_stubs")
Themed.install()
local sessions, connected = {}, true
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
package.loaded["source.kuaikan.login"] = {
    new = function()
        local session = { cancels = 0, polls = 0 }
        function session:cancel() self.cancels = self.cancels + 1 end
        function session:qrCreateAsync(cb) self.created = cb end
        function session:qrPollAsync(_uuid, _last, cb) self.polls = self.polls + 1; self.polled = cb end
        function session:exchangeAsync(code, cb) self.code, self.exchanged = code, cb end
        sessions[#sessions + 1] = session
        return session
    end,
}
local QR = require("source.kuaikan.qrlogin")
local logged = 0
local window = QR.new(function() logged = logged + 1 end)
window:start()
local session = sessions[#sessions]
Assert.is_true(Themed.last("progress_dialog").shown)
session.created("uuid")
local dialog = Themed.last("qr")
Assert.eq(dialog.caption, "用微信扫一扫")
session.polled(404)
Assert.eq(Themed.last("toast").text, "已扫码，请在手机上确认")
Stubs.flush()
session.polled(405, "confirmed")
Assert.eq(session.code, "confirmed")
session.exchanged({ user_id = "7" })
Assert.eq(logged, 1)
Assert.is_true(dialog.closed)
Assert.is_nil(window.poll)

window:start()
session = sessions[#sessions]
window:cancel()
session.created("late")
Assert.is_nil(window.dialog)
Assert.eq(session.polls, 0)
window:start()
session = sessions[#sessions]
session.created("uuid")
dialog = Themed.last("qr")
dialog:close()
session.polled(405, "late")
Assert.is_nil(session.exchanged)
Assert.eq(logged, 1)

window:start()
session = sessions[#sessions]
session.created("uuid")
Themed.last("qr").actions[1].callback()
local refreshed = sessions[#sessions]
Assert.is_true(refreshed ~= session)
session.polled(405, "old")
Assert.is_nil(session.exchanged)
refreshed.created("new")
refreshed.polled(403)
Assert.eq(Themed.last("confirm").text, "已在微信中拒绝登录")

window:start()
session = sessions[#sessions]
session.created("uuid")
window.deadline = os.time() - 1
session.polled(408)
Stubs.flush()
Assert.eq(Themed.last("confirm").text, "二维码已过期")
window:start()
session = sessions[#sessions]
session.created("uuid")
connected = false
session.polled(408)
Stubs.flush()
Assert.eq(Themed.last("confirm").text, "网络不可用，请先连接 Wi-Fi")
local count = #sessions
window:start()
Assert.eq(#sessions, count)
Assert.eq(Themed.last("toast").text, "网络不可用，请先连接 Wi-Fi")
