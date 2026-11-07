--[[--
书旗进度的各阶段取消：同步桩不能覆盖下一阶段，异步首阶段也必须可取消。

@module tests.source.shuqi.progress_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local pending
local function request(cb)
    pending = { cb = cb }
    local operation = pending
    return { cancel = function() operation.cancelled = true end }
end
local sync = false
local client = {
    loggedIn = function() return true end,
    progressAsync = function(_id, cb)
        if sync then
            cb({ chapter_id = "11", fraction = 0.5 })
            return { cancel = function() error("stale first handle") end }
        end
        return request(cb)
    end,
    putProgressAsync = function(_id, _chapter, _title, fraction, cb)
        Assert.eq(fraction, 0.5)
        return request(cb)
    end,
}
package.loaded["source.shuqi.client"] = client
package.loaded["source.toc"] = { index = function() return 1 end }
local source = require("source.shuqi").new()
local toc = { { uid = "11", title = "第一章" }, { uid = "12", title = "第二章" } }
source.loadTocAsync = function(_self, _identity, cb) return request(cb) end
local identity = { source_id = "shuqi", stable_id = "9" }
local calls = 0
local handle = source:getProgressAsync(identity, function() calls = calls + 1 end)
handle:cancel()
Assert.is_true(pending.cancelled, "异步书签请求必须可取消")
pending.cb({ chapter_id = "11", fraction = 0.5 })
Assert.eq(calls, 0)
sync = true
handle = source:getProgressAsync(identity, function() calls = calls + 1 end)
handle:cancel()
Assert.is_true(pending.cancelled, "同步书签回调后取消目录请求")
pending.cb(toc)
Assert.eq(calls, 0)
handle = source:putProgressAsync(identity, { chapter_idx = 1 }, function() calls = calls + 1 end)
handle:cancel()
Assert.is_true(pending.cancelled, "异步目录请求必须可取消")
pending.cb(toc)
Assert.eq(calls, 0)
source.loadTocAsync = function(_self, _identity, cb)
    cb(toc)
    return { cancel = function() error("stale toc handle") end }
end
handle = source:putProgressAsync(identity, { chapter_idx = 1 }, function() calls = calls + 1 end)
handle:cancel()
Assert.is_true(pending.cancelled)
pending.cb(true)
Assert.eq(calls, 0)
