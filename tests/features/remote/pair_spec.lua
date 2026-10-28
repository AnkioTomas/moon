--[[--
features.remote.pair 设备端：请求弹确认框、批准签令牌并持久化、结果只交付一次、新请求顶掉旧弹窗、撤销清表。

@module tests.features.remote.pair_spec
--]]

local Assert = require("support.assert")
require("support.stubs").install()
local Themed = require("support.theme_stubs")
Themed.install()

local store = { ["features.remote"] = { remote_paired = {} } }
local saved = 0
package.preload["utils.settings"] = function()
    return {
        get = function(owner) return store[owner] end,
        save = function() saved = saved + 1 end,
    }
end
package.preload["ffi/util"] = function()
    return { template = function(s, ...)
        local args = { ... }
        return (s:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
    end }
end
package.preload["json"] = function() return { encode = function() return "{}" end } end

local Pair = require("features.remote.pair")

-- 没配对过
Assert.is_false(Pair.isPaired("nope"))
Assert.eq(Pair.count(), 0)
Assert.eq(Pair.poll("zzz"), "denied")

-- 发起：弹确认框，文案带浏览器名与 IP；未批前轮询 pending
local id = Pair.request("Chrome · macOS", "192.168.1.9")
Assert.eq(#id, 32)
local dlg = Themed.last("confirm")
Assert.is_true(dlg.shown)
Assert.matches(dlg.text, "Chrome · macOS")
Assert.matches(dlg.text, "192.168.1.9")
Assert.eq(Pair.poll(id), "pending")

-- 允许：签令牌、持久化、轮询拿到一次 approved + token，之后该 id 作废
dlg.ok_callback()
local state, token = Pair.poll(id)
Assert.eq(state, "approved")
Assert.eq(#token, 32)
Assert.is_true(Pair.isPaired(token))
Assert.eq(store["features.remote"].remote_paired[token].name, "Chrome · macOS")
Assert.is_true(saved >= 1)
Assert.eq(Pair.count(), 1)
Assert.eq(Pair.poll(id), "denied", "结果只交付一次")

-- 拒绝：denied 且不签令牌
local id2 = Pair.request("Safari · iOS", nil)
Themed.last("confirm").cancel_callback()
local state2, token2 = Pair.poll(id2)
Assert.eq(state2, "denied")
Assert.is_nil(token2)
Assert.eq(Pair.count(), 1)

-- 新请求顶掉旧的：旧弹窗被关（不走回调），旧 id 轮询 denied；旧弹窗的回调即使晚到也不生效
local id3 = Pair.request("A", "1.1.1.1")
local old = Themed.last("confirm")
local id4 = Pair.request("B", "2.2.2.2")
Assert.is_true(old.closed)
Assert.eq(Pair.poll(id3), "denied")
old.ok_callback()
Assert.eq(Pair.poll(id4), "pending", "被顶掉的弹窗回调不影响新请求")
Assert.eq(Pair.count(), 1)

-- 停服丢弃：弹窗关掉，轮询 denied
Pair.cancel()
Assert.is_true(Themed.last("confirm").closed)
Assert.eq(Pair.poll(id4), "denied")

-- 撤销全部
Pair.revokeAll()
Assert.is_false(Pair.isPaired(token))
Assert.eq(Pair.count(), 0)
