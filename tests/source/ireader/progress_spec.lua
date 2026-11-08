--[[--
掌阅章节进度、离线旧目录、写入失败与同步回调取消。

@module tests.source.ireader.progress_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local requests, connected, read_async, toc_async = {}, false, false, false
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
local toc = { { uid = "1", title = "甲", toc_version = 0 }, { uid = "2", title = "乙" } }
package.loaded["source.toc"] = {
    read = function() return toc end,
    index = function(_sid, _bid, uid) return uid == "2" and 2 or nil end,
}
package.loaded["source.ireader.client"] = {
    session = function() return { usr = "test", zysid = "test" } end,
    progressAsync = function(_id, cb)
        if read_async then
            local item = { cb = cb }
            requests[#requests + 1] = item
            return { cancel = function() item.cancelled = true end }
        end
        cb({ readProcess = { chapterId = "1", readPercent = "0.2" } })
        return { cancel = function() end }
    end,
    putProgressAsync = function(_id, uid, total, cb)
        local item = { uid = uid, total = total, cb = cb }
        requests[#requests + 1] = item
        return { cancel = function() item.cancelled = true end }
    end,
}
local source = require("source.ireader").new()
local result, reason, calls = nil, nil, 0
local function done(value, err) result, reason, calls = value, err, calls + 1 end
local identity = { source_id = "ireader", stable_id = "test", chapter_idx = 2 }
source:loadTocAsync(identity, done)
require("support.stubs").flush()
Assert.eq(result, toc, "离线不强制刷新旧目录")
function source:loadTocAsync(_identity, cb)
    if toc_async then
        local item = { cb = cb }
        requests[#requests + 1] = item
        return { cancel = function() item.cancelled = true end }
    end
    cb(toc)
    return { cancel = function() end }
end
source:getProgressAsync(identity, done)
Assert.eq(result.chapter_idx, 2)
Assert.eq(result.fraction, .5, "章式正文不使用只属于 TXT/PDF 的 readPercent")
local handle = source:putProgressAsync(identity, {}, done)
local pending = requests[#requests]
local before = calls
handle:cancel()
Assert.is_true(pending.cancelled)
pending.cb(true)
Assert.eq(calls, before)
source:putProgressAsync(identity, {}, done)
requests[#requests].cb(nil, "network failed")
Assert.is_nil(result)
Assert.eq(reason, "network failed")
Assert.eq(requests[#requests].uid, "2")
Assert.eq(requests[#requests].total, 2)

read_async = true
handle = source:getProgressAsync(identity, done)
pending = requests[#requests]
before = calls
handle:cancel()
Assert.is_true(pending.cancelled, "取消初始异步进度查询")
pending.cb({ readProcess = { chapterId = "1" } })
Assert.eq(calls, before)

read_async, toc_async = false, true
handle = source:getProgressAsync(identity, done)
pending = requests[#requests]
handle:cancel()
Assert.is_true(pending.cancelled, "同步进度查询后取消异步目录")
pending.cb(toc)
Assert.eq(calls, before)

handle = source:putProgressAsync(identity, {}, done)
pending = requests[#requests]
handle:cancel()
Assert.is_true(pending.cancelled, "取消上传前的异步目录")
pending.cb(toc)
Assert.eq(calls, before)
