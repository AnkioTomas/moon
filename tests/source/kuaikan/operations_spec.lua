--[[--
快看源操作：命中旧缓存可离线开书，同步目录桩后取消仍指向章节任务。

@module tests.source.kuaikan.operations_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Themed = require("support.theme_stubs")
Themed.install()
local toc = { { idx = 1, uid = "1", toc_version = 1 }, { idx = 2, uid = "2" } }
local connected, cached, touched = true, false, nil
package.loaded["source.toc"] = { read = function() return toc end }
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
package.loaded["book.progress_db"] = { get = function() return { chapter_idx = 2 } end }
package.loaded["book.store"] = {
    touch = function(path, _identity, meta) touched = { path, meta.chapter_idx }; return true end,
}
local pending, cancelled = nil, {}
package.loaded["source.kuaikan.chapter"] = {
    existing = function(_identity, chapter) return cached and "/" .. chapter.uid .. ".cbz" or nil end,
    materializeAsync = function(_identity, _chapter, _progress, cb)
        pending = cb
        return { cancel = function() cancelled.chapter = true end }
    end,
    prefetchAsync = function(_identity, _toc, from, count, _opts, cb)
        Assert.eq(from, 0)
        Assert.eq(count, 2)
        pending = cb
        return { cancel = function() cancelled.cache = true end }
    end,
}
local source = require("source.kuaikan").new()
source.loadTocAsync = function(_self, _identity, cb)
    cb(toc)
    return { cancel = function() cancelled.toc = true end }
end
local identity = { source_id = "kuaikan", stable_id = "book" }
local called = false
local handle = source:openBookAsync(identity, nil, function() called = true end)
Stubs.flush()
handle.cancel()
Assert.is_true(cancelled.chapter)
Assert.is_nil(cancelled.toc)
Assert.is_true(Themed.last("progress_dialog").closed)
pending("/1.cbz")
Assert.is_false(called)
Assert.is_nil(touched)

handle = source:cacheAllChaptersAsync(identity, nil, function() called = true end)
handle.cancel()
Assert.is_true(cancelled.cache)
Assert.is_nil(cancelled.toc)
pending(2, 2, 0)
Assert.is_false(called)

connected, cached = false, true
local opened
source:openBookAsync(identity, nil, function(path) opened = path end)
Stubs.flush()
Assert.eq(opened, "/2.cbz")
Assert.eq(touched[2], 2)
cached = false
source:openBookAsync(identity, nil, function(path, err)
    Assert.is_nil(path)
    Assert.eq(err, "网络不可用，请先连接 Wi-Fi")
end)
Stubs.flush()
