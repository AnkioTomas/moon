--[[--
掌阅扫码校验、刷新、失败、取消和同步回调的句柄所有权。

@module tests.source.ireader.qrlogin_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
local Stubs = require("support.stubs")
Themed.install()
local connected, mode, requests, logged = true, "delayed", {}, 0
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
local function request(kind, cb)
    local item = { kind = kind, cb = cb }
    requests[#requests + 1] = item
    if kind == "create" and mode == "sync" then cb("test-code") end
    return { cancel = function() item.cancelled = true end }
end
package.loaded["source.ireader.client"] = {
    qrCreateAsync = function(cb) return request("create", cb) end,
    qrPollAsync = function(_code, cb) return request("poll", cb) end,
    checkSessionAsync = function(_user, cb) return request("check", cb) end,
}
local QR = require("source.ireader.qrlogin")
local window = QR:new(function() logged = logged + 1 end)
local login = { code = 0, body = { name = "test-user", session_id = "test-session" } }
mode = "sync"
window:start()
local poll = requests[#requests]
Assert.eq(poll.kind, "poll")
window:cancel()
Assert.is_true(poll.cancelled)
poll.cb(login)
Assert.eq(logged, 0)

window:start()
requests[#requests].cb({ code = 30059 })
Stubs.flush()
Assert.eq(requests[#requests].kind, "poll")
requests[#requests].cb(login)
local checking = requests[#requests]
Assert.eq(checking.kind, "check")
Assert.eq(logged, 0, "校验成功前不保存新账号")
local dialog = Themed.last("qr")
checking.cb(true)
Assert.eq(logged, 1)
Assert.is_true(dialog.closed)
Assert.is_nil(Themed.last("toast"), "成功关闭二维码不能误报已取消")

window:start()
dialog = Themed.last("qr")
dialog.actions[1].callback()
Assert.is_true(dialog.closed)
local old_poll = poll
old_poll.cb(login)
Assert.eq(logged, 1)
requests[#requests].cb(nil, "network failed")
Assert.eq(Themed.last("confirm").text, "network failed")
window:start()
requests[#requests].cb(login)
checking = requests[#requests]
dialog = Themed.last("qr")
dialog:close()
Assert.is_true(checking.cancelled)
checking.cb(true)
Assert.eq(logged, 1)

window:start()
window.deadline = os.time() - 1
requests[#requests].cb({ code = 30059 })
Stubs.flush()
Assert.eq(Themed.last("confirm").text, "二维码已过期")
connected = false
local count = #requests
window:start()
Assert.eq(#requests, count)
Assert.eq(Themed.last("toast").text, "网络不可用，请先连接 Wi-Fi")

connected, mode = true, "delayed"
window:start()
local creating = requests[#requests]
window:cancel()
creating.cb("late-code")
Assert.is_nil(window.dialog)
Assert.eq(logged, 1)
