--[[--
features.bluetooth：守护进程状态三态、顶栏读数、开关 / 连接 / 配对的请求序列（HTTP 打桩，无设备）。
@module tests.features.bluetooth.init_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field, need-check-nil

local Assert = require("support.assert")
local Stubs = require("support.stubs")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["json"] = function() return { decode = require("support.json_stub").decode } end

-- 按路径（不含 query）给响应：字符串 = JSON 体，false = 连不上；数组按次序消费，最后一个重复用。
local routes, calls = {}, {}
package.preload["http.request"] = function()
    return {
        get = function(url, _opts, cb)
            local path = url:match("^http://127%.0%.0%.1:8321(/[^?]*)")
            calls[#calls + 1] = url:match("^http://127%.0%.0%.1:8321(.*)$")
            local r = routes[path]
            if type(r) == "table" then
                local v = r[1]
                if #r > 1 then table.remove(r, 1) end
                r = v
            end
            local cancelled = false
            require("ui/uimanager"):nextTick(function()
                if cancelled then return end
                if r then cb(r) else cb(nil, "connection refused") end
            end)
            return { cancel = function() cancelled = true end }
        end,
    }
end

local spawned = 0
local real_execute = os.execute
os.execute = function(cmd)
    if cmd:find("kindle-hid-passthrough", 1, true) then
        spawned = spawned + 1
        return 0
    end
    return real_execute(cmd)
end

local Bluetooth = require("features.bluetooth")

local STOPPED = '{"ok":true,"daemon_running":false,"devices":[],"connections":[]}'
local ON_EMPTY = '{"ok":true,"daemon_running":true,'
    .. '"devices":[{"address":"AA:BB","protocol":"ble","name":"BLE-M3"},{"address":"CC:DD","protocol":"classic"}],'
    .. '"connections":[]}'
local ON_ONE = '{"ok":true,"daemon_running":true,'
    .. '"devices":[{"address":"AA:BB","protocol":"ble","name":"BLE-M3"}],'
    .. '"connections":[{"address":"aa:bb","protocol":"ble","name":"BLE-M3"}]}'
local ON_TWO = '{"ok":true,"daemon_running":true,"devices":[],'
    .. '"connections":[{"address":"AA:BB","protocol":"ble","name":"A"},{"address":"CC:DD","protocol":"ble","name":"B"}]}'

local function reset()
    routes, calls, spawned = {}, {}, 0
end

-- 没装守护进程：watch 不轮询、不发请求。
do
    reset()
    Bluetooth.installed = function() return false end
    local h = Bluetooth.watch(function() end)
    Stubs.flush()
    Assert.len(calls, 0)
    h.cancel()
    Assert.is_nil(Bluetooth.topbar())
    Assert.len(require("features.bluetooth.topbar").items(), 0, "没装不出顶栏项，设置页也没有开关")
end

-- 三态与顶栏读数；地址大小写不敏感。
do
    reset()
    Bluetooth.refresh()
    Stubs.flush()
    Assert.eq(Bluetooth.current().state, "off")
    local text, icon = Bluetooth.topbar()
    Assert.is_nil(text)
    Assert.eq(icon, "bluetooth_disabled")

    routes["/status"] = ON_EMPTY
    Bluetooth.refresh()
    Stubs.flush()
    text, icon = Bluetooth.topbar()
    Assert.is_nil(text)
    Assert.eq(icon, "bluetooth")
    Assert.eq(Bluetooth.name(Bluetooth.current().devices[2]), "CC:DD")

    routes["/status"] = ON_ONE
    Bluetooth.refresh()
    Stubs.flush()
    text, icon = Bluetooth.topbar()
    Assert.eq(text, "BLE-M3")
    Assert.eq(icon, "bluetooth_connected")
    Assert.is_true(Bluetooth.isConnected(Bluetooth.current(), "AA:BB"))

    routes["/status"] = ON_TWO
    Bluetooth.refresh()
    Stubs.flush()
    Assert.eq((Bluetooth.topbar()), "2")
end

-- watch：订阅即读一次并通知；取消后不再通知。
do
    reset()
    Bluetooth.installed = function() return true end
    routes["/status"] = STOPPED
    local hits = 0
    local h = Bluetooth.watch(function() hits = hits + 1 end)
    h.cancel() -- 先取消轮询定时器，否则 flush 会无限跑下一轮
    Stubs.flush()
    Assert.eq(Bluetooth.current().state, "stopped")
    Assert.eq(hits, 0)
end

-- 打开：stopped → /start → 等到 on。
do
    reset()
    routes["/status"] = { STOPPED, STOPPED, ON_EMPTY }
    routes["/start"] = '{"ok":true}'
    local ok
    Bluetooth.setEnabled(true, function(r) ok = r end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.eq(calls[2], "/start")
    Assert.eq(spawned, 0)
end

-- 打开：守护进程没跑 → 拉起 → 接口起来后 /start。
do
    reset()
    routes["/status"] = { false, STOPPED, STOPPED, ON_EMPTY }
    routes["/start"] = '{"ok":true}'
    local ok
    Bluetooth.setEnabled(true, function(r) ok = r end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.eq(spawned, 1)
    Assert.contains(calls, "/start")
end

-- 已是目标状态：只读一次 /status。关闭时守护进程没跑也算已关。
do
    reset()
    local ok
    Bluetooth.setEnabled(false, function(r) ok = r end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.len(calls, 1)
    Assert.eq(spawned, 0)
end

-- 关闭失败：/stop 报错原样回给调用方。
do
    reset()
    routes["/status"] = ON_EMPTY
    routes["/stop"] = '{"ok":false,"error":"busy"}'
    local ok, err
    Bluetooth.setEnabled(false, function(r, e) ok, err = r, e end)
    Stubs.flush()
    Assert.is_false(ok)
    Assert.eq(err, "busy")
end

-- 连接：带地址与协议，等到连接表出现该设备。
do
    reset()
    routes["/status"] = { ON_EMPTY, ON_ONE }
    routes["/connect"] = '{"ok":true}'
    local ok
    Bluetooth.setConnected({ address = "AA:BB", protocol = "ble" }, true, function(r) ok = r end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.eq(calls[1], "/connect?addr=AA%3ABB&protocol=ble")
end

-- 配对：轮询 /pair-status 到结束；失败带守护进程的错误。
do
    reset()
    routes["/pair"] = '{"ok":true}'
    routes["/pair-status"] = { '{"ok":true,"pairing":true}', '{"ok":true,"address":"AA:BB"}' }
    local ok
    Bluetooth.pair({ address = "AA:BB", protocol = "classic", name = "Pad X" }, function(r) ok = r end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.eq(calls[1], "/pair?addr=AA%3ABB&protocol=classic&name=Pad%20X")

    reset()
    routes["/pair"] = '{"ok":true}'
    routes["/pair-status"] = '{"ok":false,"error":"auth failed"}'
    local err
    Bluetooth.pair({ address = "AA:BB" }, function(r, e) ok, err = r, e end)
    Stubs.flush()
    Assert.is_false(ok)
    Assert.eq(err, "auth failed")
end

-- 扫描：扫描中多次 on_update，结束 on_done；取消后不再回调。
do
    reset()
    routes["/scan"] = '{"ok":true}'
    routes["/scan-status"] = {
        '{"ok":true,"scanning":true,"devices":[{"address":"AA:BB","protocol":"ble"}]}',
        '{"ok":true,"scanning":false,"devices":[{"address":"AA:BB","protocol":"ble"},{"address":"CC:DD","protocol":"classic"}]}',
    }
    local updates, done = 0, nil
    Bluetooth.scan(function() updates = updates + 1 end, function(devices) done = devices end)
    Stubs.flush()
    Assert.eq(updates, 1)
    Assert.len(done, 2)

    reset()
    routes["/scan"] = '{"ok":true}'
    routes["/scan-status"] = '{"ok":true,"scanning":true,"devices":[]}'
    done = nil
    local h = Bluetooth.scan(function() end, function(devices) done = devices end)
    h.cancel()
    Stubs.flush()
    Assert.is_nil(done)
end

os.execute = real_execute
