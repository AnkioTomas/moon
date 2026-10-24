--[[--
features.bluetooth 原生后端（Kindle btfd，lipc 打桩，无设备）：状态映射、开关 / 连接 / 配对 / 扫描的 lipc 调用序列。
@module tests.features.bluetooth.kindle_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field, need-check-nil

local Assert = require("support.assert")
local Stubs = require("support.stubs")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["json"] = function() return { decode = require("support.json_stub").decode } end
package.preload["http.request"] = function() return { get = function() error("原生后端不走 HTTP") end } end
package.preload["device"] = function() return { isKindle = function() return true end } end

-- btfd 状态：state 即 BTstate，hashes 按属性名给哈希行，sets 记录写入。
local btfd = { state = 1, hashes = {}, sets = {} }
package.preload["liblipclua"] = function()
    return {
        init = function()
            return {
                get_int_property = function() return btfd.state end,
                set_string_property = function(_self, _svc, prop, value)
                    btfd.sets[#btfd.sets + 1] = prop .. "=" .. value
                    if prop == "BTenable" and value:sub(1, 1) == "1" then btfd.state = 1 end
                end,
                set_int_property = function(_self, _svc, prop, value)
                    btfd.sets[#btfd.sets + 1] = prop .. "=" .. value
                    if prop == "BTflightMode" and value == 1 then btfd.state = 0 end
                end,
                close = function() end,
            }
        end,
    }
end
package.preload["libopenlipclua"] = function()
    return {
        open_no_name = function()
            return {
                new_hasharray = function() return { destroy = function() end } end,
                access_hash_property = function(_self, _svc, prop)
                    local rows = btfd.hashes[prop] or {}
                    return { to_table = function() return rows end, destroy = function() end }
                end,
                close = function() end,
            }
        end,
    }
end

-- lfs 里没有守护进程二进制：走原生后端。
local Bluetooth = require("features.bluetooth")

btfd.hashes.ListPaired = { { address = "aa-bb-cc-dd-ee-ff", name = "Kindle Click" }, { junk = "x" } }
btfd.hashes.ListConnected = { { bdaddr = "AA:BB:CC:DD:EE:FF" } }

-- 状态：BTstate 非 0 为 on；哈希行地址归一成大写冒号，没有地址的行丢弃。
do
    Assert.is_true(Bluetooth.installed())
    local got
    Bluetooth.refresh(function(st) got = st end)
    Assert.eq(got.state, "on")
    Assert.len(got.devices, 1)
    Assert.eq(got.devices[1].address, "AA:BB:CC:DD:EE:FF")
    Assert.is_true(Bluetooth.isConnected(got, "aa:bb:cc:dd:ee:ff"))
    Assert.eq(select(2, Bluetooth.topbar()), "bluetooth_connected")
end

-- 开关：关写 BTflightMode=1（BTenable 0:x 在 ACE 栈上关不掉），开写 BTenable 1:2；状态翻转后回调成功；已经是目标状态不写。
do
    btfd.sets = {}
    local ok
    Bluetooth.setEnabled(false, function(done) ok = done end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.eq(btfd.sets[1], "BTflightMode=1")
    Assert.eq(Bluetooth.current().state, "stopped")
    Assert.eq(#Bluetooth.current().devices, 0, "关闭后不列设备")

    btfd.sets = {}
    Bluetooth.setEnabled(false, function(done) ok = done end)
    Assert.len(btfd.sets, 0)
    Bluetooth.setEnabled(true, function(done) ok = done end)
    Stubs.flush()
    Assert.eq(btfd.sets[1], "BTflightMode=0")
    Assert.eq(btfd.sets[2], "BTenable=1:2")
end

-- 断开：写 Disconnect，连接表还在时超时失败不挂起。
do
    btfd.sets = {}
    local dev = { address = "AA:BB:CC:DD:EE:FF" }
    Bluetooth.setConnected(dev, false, function() end)
    Stubs.flush()
    Assert.eq(btfd.sets[1], "Disconnect=AA:BB:CC:DD:EE:FF")
end

-- 配对：Bond 后设备出现在已配对表里就连接并成功。
do
    btfd.sets = {}
    local ok
    Bluetooth.pair({ address = "AA:BB:CC:DD:EE:FF" }, function(done) ok = done end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.eq(btfd.sets[1], "Bond=AA:BB:CC:DD:EE:FF")
    Assert.eq(btfd.sets[2], "Connect=AA:BB:CC:DD:EE:FF")
end

-- 扫描：触发 triggerBTscan，结束时给出发现的设备；取消后不再回调。
do
    btfd.sets = {}
    btfd.hashes.ListDiscovered = { { address = "11:22:33:44:55:66", name = "BLE-M3" } }
    local done
    Bluetooth.scan(function() end, function(devices) done = devices end)
    Stubs.flush()
    Assert.eq(btfd.sets[1], "triggerBTscan=1")
    Assert.len(done, 1)
    Assert.eq(done[1].name, "BLE-M3")

    done = nil
    Bluetooth.scan(function() end, function(devices) done = devices end).cancel()
    Stubs.flush()
    Assert.is_nil(done)
end
