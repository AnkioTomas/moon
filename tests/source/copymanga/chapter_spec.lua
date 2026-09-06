--[[--
拷贝漫画章节预取 / 全书缓存用例。

@module tests.source.copymanga.chapter_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()

package.preload["ffi/archiver"] = function()
    return { Writer = { new = function() return {} end } }
end
package.preload["utils.paths"] = function()
    return { ensureBookWork = function() end, bookWorkDir = function() return "/tmp" end }
end
package.preload["source.copymanga.protocol"] = function()
    return { chapterImages = function() end }
end
package.preload["source.copymanga.client"] = function()
    return { headers = function() return {} end }
end
package.loaded["source.copymanga.chapter"] = nil

local Chapter = require("source.copymanga.chapter")

local calls = {}
local fail_at
Chapter.materializeAsync = function(_, _, _, idx, _, cb)
    calls[#calls + 1] = idx
    if fail_at == idx then
        require("ui/uimanager"):nextTick(function() cb(nil, "fail") end)
    else
        require("ui/uimanager"):nextTick(function() cb("/tmp/" .. idx .. ".cbz") end)
    end
    return { cancel = function() end }
end

local toc = {
    { idx = 1, uid = "a" },
    { idx = 2, uid = "b" },
    { idx = 3, uid = "c" },
    { idx = 4, uid = "d" },
    { idx = 5, uid = "e" },
}
local identity = { source_id = "copymanga", stable_id = "comic" }

do
    local cached, total, failed
    Chapter.prefetchAsync({}, identity, toc, 2, 3, nil, function(c, t, f)
        cached, total, failed = c, t, f
    end)
    Stubs.flush()
    Assert.eq(calls[1], 3)
    Assert.eq(calls[2], 4)
    Assert.eq(calls[3], 5)
    Assert.len(calls, 3)
    Assert.eq(cached, 3)
    Assert.eq(total, 3)
    Assert.eq(failed, 0)
end

do
    calls = {}
    local cached, total, failed
    Chapter.prefetchAsync({}, identity, toc, 5, 3, nil, function(c, t, f)
        cached, total, failed = c, t, f
    end)
    Stubs.flush()
    Assert.len(calls, 0)
    Assert.eq(cached, 0)
    Assert.eq(total, 0)
    Assert.eq(failed, 0)
end

do
    calls = {}
    fail_at = 4
    local cached, total, failed, last_err
    local progressed = {}
    Chapter.prefetchAsync({}, identity, toc, 2, 3, {
        progress = function(done, all) progressed[#progressed + 1] = { done, all } end,
    }, function(c, t, f, err)
        cached, total, failed, last_err = c, t, f, err
    end)
    Stubs.flush()
    Assert.len(calls, 3)
    Assert.eq(cached, 2)
    Assert.eq(total, 3)
    Assert.eq(failed, 1)
    Assert.eq(last_err, "fail")
    Assert.eq(progressed[#progressed][1], 3)
    Assert.eq(progressed[#progressed][2], 3)
    fail_at = nil
end

do
    calls = {}
    local cached
    Chapter.prefetchAsync({}, identity, toc, 0, #toc, {
        interval_seconds = 1.5,
    }, function(c) cached = c end)
    Stubs.flush()
    Assert.len(calls, 5)
    Assert.eq(cached, 5)
end

do
    calls = {}
    local done = false
    local job = Chapter.prefetchAsync({}, identity, toc, 1, 3, nil, function() done = true end)
    job.cancel()
    Stubs.flush()
    Assert.len(calls, 0)
    Assert.is_false(done)
end
