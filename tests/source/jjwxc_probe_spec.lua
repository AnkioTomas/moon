--[[--
晋江 VIP 章购买状态探测：句柄挂在源实例上，目录重拉前取消在飞探测，旧目录表不能盖回新目录。

@module tests.source.jjwxc_probe_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["utils.settings"] = function()
    return { getSource = function() return {} end, saveSource = function() end }
end

-- 内存目录表：put 记每次写入的表
local stored, puts = {}, {}
package.preload["source.toc"] = function()
    return {
        read = function(_source_id, stable_id) return stored[stable_id] end,
        put = function(_source_id, stable_id, list)
            stored[stable_id] = list
            puts[#puts + 1] = list
            return true
        end,
    }
end

-- Web 协议：paidAsync 挂起，由用例手动回
local pending = {}
local Web = {
    id = "web",
    paidAsync = function(_novel, uid, cb)
        local req = { uid = uid, cb = cb, cancelled = false }
        req.cancel = function() req.cancelled = true end
        pending[#pending + 1] = req
        return req
    end,
}
package.preload["source.jjwxc.protocols.web"] = function() return Web end
package.preload["source.jjwxc.protocols"] = function()
    return { list = { Web }, current = function() return Web end }
end

local chapter_cbs = {}
package.preload["source.jjwxc.client"] = function()
    return {
        chaptersAsync = function(_id, cb)
            chapter_cbs[#chapter_cbs + 1] = cb
            return { cancel = function() end }
        end,
    }
end
package.preload["source.jjwxc.mapper"] = function()
    return {
        TOC_VERSION = 7,
        toc = function(wire) return wire end,
    }
end

for _idx, name in ipairs({ "source.jjwxc", "source.jjwxc.init", "source.toc", "source.jjwxc.protocols",
    "source.jjwxc.protocols.web", "source.jjwxc.client", "source.jjwxc.mapper", "utils.settings" }) do
    package.loaded[name] = nil
end
local Jjwxc = require("source.jjwxc")

local function vipToc()
    return {
        { uid = "1", idx = 1, title = "一", vip = true, toc_version = 7 },
        { uid = "2", idx = 2, title = "二", vip = true, toc_version = 7 },
    }
end
local identity = { source_id = "jjwxc", stable_id = "9" }

-- 缓存命中：开探测；同一本书再问不重开；问完一次性写回
do
    stored["9"] = vipToc()
    local src = Jjwxc.new()
    src:loadTocAsync(identity, function() end)
    Stubs.flush()
    Assert.len(pending, 1)
    Assert.eq(src.probe.stable_id, "9")
    src:loadTocAsync(identity, function() end)
    Stubs.flush()
    Assert.len(pending, 1, "同一本书在飞不重开")
    pending[1].cb(true)
    Assert.len(pending, 2)
    pending[2].cb(false)
    Assert.is_nil(src.probe)
    Assert.len(puts, 1)
    Assert.eq(puts[1][1].paid, true)
    Assert.eq(puts[1][2].paid, false)
    pending, puts, stored = {}, {}, {}
end

-- 目录重拉：在飞的探测先取消，旧目录表不能在新目录之后写回
do
    stored["9"] = vipToc()
    local src = Jjwxc.new()
    src:loadTocAsync(identity, function() end)
    Stubs.flush()
    Assert.len(pending, 1)
    local old_probe_req = pending[1]
    stored["9"] = nil -- 缓存失效，下一次走网络
    local got
    src:loadTocAsync(identity, function(toc) got = toc end)
    local fresh = vipToc()
    fresh[1].title = "新一"
    chapter_cbs[1](fresh)
    Assert.eq(got[1].title, "新一")
    Assert.is_true(old_probe_req.cancelled, "重拉前取消旧探测")
    old_probe_req.cb(true) -- 迟到的回包
    Assert.eq(stored["9"][1].title, "新一", "旧表不能盖回新目录")
    Assert.is_nil(stored["9"][1].paid)
    -- 新目录自己的探测在跑
    Assert.eq(src.probe.stable_id, "9")
    Assert.len(pending, 2)
    pending, puts, stored, chapter_cbs = {}, {}, {}, {}
end

-- 换书：旧书探测取消；close 取消在飞探测
do
    stored["9"] = vipToc()
    stored["10"] = vipToc()
    local src = Jjwxc.new()
    src:loadTocAsync(identity, function() end)
    Stubs.flush()
    src:loadTocAsync({ source_id = "jjwxc", stable_id = "10" }, function() end)
    Stubs.flush()
    Assert.is_true(pending[1].cancelled)
    Assert.eq(src.probe.stable_id, "10")
    src:close()
    Assert.is_true(pending[2].cancelled)
    Assert.is_nil(src.probe)
    pending[2].cb(true)
    Assert.len(puts, 0, "取消后不落库")
    pending, puts, stored = {}, {}, {}
end
