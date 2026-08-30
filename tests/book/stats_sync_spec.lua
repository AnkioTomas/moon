--[[-- book.stats：只搬运领域记录；网络和上传策略属于 Source。 --]]

local Assert = require("support.assert")

local pending_rows = {
    { id = 1, stable_id = "a.epub", page = 1, start_time = 1000, duration = 30, total_pages = 300 },
}
local confirmed
local confirm_ok = true
package.preload["db.stats"] = function()
    return {
        unsyncedBySource = function() return pending_rows end,
        markSynced = function(ids)
            confirmed = ids
            return confirm_ok
        end,
    }
end
package.preload["ui/network/manager"] = function()
    error("book.stats 不得加载 NetworkMgr")
end
package.loaded["db.stats"] = nil
package.loaded["book.stats"] = nil

local Stats = require("book.stats")
local source_callback
local received
local source = {
    id = "moon",
    pushStatsAsync = function(_, rows, cb)
        received = rows
        source_callback = cb
        return { cancel = function() end }
    end,
}

local done_ok, done_result
local job = Stats.push(source, function(ok, result)
    done_ok, done_result = ok, result
end)
Assert.not_nil(job)
Assert.eq(received, pending_rows)
Assert.is_nil(received[1].device_id, "book.stats 不能拼 Source 协议字段")
source_callback({ ok = true })
Assert.is_true(done_ok)
Assert.not_nil(done_result)
Assert.eq(confirmed[1], 1)

confirm_ok = false
done_ok, done_result, confirmed = nil, nil, nil
Stats.push(source, function(ok, result) done_ok, done_result = ok, result end)
source_callback({ ok = true })
Assert.is_false(done_ok)
Assert.not_nil(done_result)

pending_rows = {}
done_ok, done_result = nil, nil
Assert.is_nil(Stats.push(source, function(ok, result) done_ok, done_result = ok, result end))
Assert.is_true(done_ok)
Assert.eq(done_result, "empty")
