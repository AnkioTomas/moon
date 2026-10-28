--[[--
阅读（Legado）进度推送：返回的句柄要能取消真正在飞的 saveBookProgress 请求，取消后不再回调。

@module tests.source.legado_progress_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local row = { bookUrl = "u1", name = "书", author = "人", durChapterIndex = 0, durChapterPos = 0 }
local saves = {}
package.preload["source.legado.client"] = function()
    return {
        base = function() return "http://h" end,
        shelfAsync = function(cb)
            cb({ row })
            return { cancel = function() end }
        end,
        saveProgressAsync = function(_row, pos, cb)
            local req = { pos = pos, cb = cb, cancelled = false }
            req.cancel = function() req.cancelled = true end
            saves[#saves + 1] = req
            return req
        end,
    }
end
package.preload["source.legado.mapper"] = function()
    return { readPos = function() return { index = 0, offset = 3 } end }
end
package.preload["source.toc"] = function()
    return { read = function() return { { uid = "c1", idx = 1, title = "一" }, { uid = "c2", idx = 2, title = "二" } } end }
end
for _idx, name in ipairs({ "source.legado", "source.legado.client", "source.legado.mapper", "source.toc" }) do
    package.loaded[name] = nil
end
local Legado = require("source.legado")

local identity = { source_id = "legado", stable_id = "u1" }

-- 正常：推到第二章，回调 ok
do
    local src = Legado.new()
    local got_ok, got_err
    src:putProgressAsync(identity, { chapter_idx = 2 }, function(ok, err) got_ok, got_err = ok, err end)
    Stubs.flush()
    Assert.len(saves, 1)
    Assert.eq(saves[1].pos.index, 1)
    Assert.eq(saves[1].pos.offset, 0, "换章 offset 归零")
    saves[1].cb(true)
    Assert.is_true(got_ok, got_err)
    saves = {}
end

-- 取消：传到在飞的保存请求；迟到的回包不再投递
do
    local src = Legado.new()
    local called = false
    local handle = src:putProgressAsync(identity, { chapter_idx = 1 }, function() called = true end)
    Stubs.flush()
    Assert.len(saves, 1)
    Assert.eq(saves[1].pos.offset, 3, "同章保留 offset")
    handle.cancel()
    Assert.is_true(saves[1].cancelled, "取消没有传到保存请求")
    saves[1].cb(true)
    Assert.is_false(called, "取消后不能再回调")
    saves = {}
end
