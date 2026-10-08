local Assert = require("support.assert")
local JsonStub = require("support.json_stub")

package.preload["gettext"] = function()
    return function(text) return text end
end
package.preload["json"] = function()
    return { encode = JsonStub.encode, decode = JsonStub.decode }
end

--- 补全循环测试用的假调度器：记录延迟，手动 step 推进。
local function newFake()
    local f = { delays = {}, queue = {} }
    function f.schedule(delay, fn)
        f.delays[#f.delays + 1] = delay
        local entry = { fn = fn, cancelled = false }
        f.queue[#f.queue + 1] = entry
        return { cancel = function() entry.cancelled = true end }
    end
    function f.step()
        local entry = table.remove(f.queue, 1)
        if entry and not entry.cancelled then entry.fn() end
    end
    return f
end

-- ── Backfill 模块单测 ─────────────────────────────────────────────

local Backfill = require("source.kavita.backfill")

local planned = Backfill.plan(
    { ["1"] = "a", ["2"] = "b", ["3"] = "" },
    { ["1"] = "a", ["2"] = "old" }
)
Assert.len(planned, 2)
Assert.eq(planned[1].stable_id, "2")
Assert.eq(planned[2].stable_id, "3")
Assert.eq(planned[2].ts, "")

local fake = newFake()
local fetched, saved = {}, {}
local bf = Backfill.new{
    schedule = fake.schedule,
    fetch = function(item, cb)
        fetched[#fetched + 1] = item.stable_id
        cb({ summary = "s" })
        return { cancel = function() end }
    end,
    on_success = function(item) saved[#saved + 1] = item.stable_id end,
}
bf:run({ { stable_id = "1", ts = "a" }, { stable_id = "2", ts = "b" } })
Assert.len(fetched, 1)
Assert.eq(fetched[1], "1")
Assert.len(fake.delays, 1)
Assert.eq(fake.delays[1], 0.3)
fake.step()
Assert.len(fetched, 2)
Assert.eq(fetched[2], "2")
Assert.len(saved, 2)

-- 失败退避 15 / 30，第三次成功
local retry_fake = newFake()
local attempts, ok_n = 0, 0
local retry_bf = Backfill.new{
    schedule = retry_fake.schedule,
    fetch = function(_, cb)
        attempts = attempts + 1
        if attempts < 3 then cb(nil, "boom") else cb({ summary = "ok" }) end
        return { cancel = function() end }
    end,
    on_success = function() ok_n = ok_n + 1 end,
}
retry_bf:run({ { stable_id = "1", ts = "t" } })
Assert.eq(attempts, 1)
Assert.eq(retry_fake.delays[1], 15)
retry_fake.step()
Assert.eq(attempts, 2)
Assert.eq(retry_fake.delays[2], 30)
retry_fake.step()
Assert.eq(attempts, 3)
Assert.eq(ok_n, 1)
Assert.eq(retry_fake.delays[3], 0.3)

-- on_done：队列走完回调一次（供一次性落盘状态用）
local done_fake = newFake()
local done_n = 0
local done_bf = Backfill.new{
    schedule = done_fake.schedule,
    fetch = function(_, cb)
        cb({})
        return { cancel = function() end }
    end,
    on_success = function() end,
    on_done = function() done_n = done_n + 1 end,
}
done_bf:run({ { stable_id = "1", ts = "t" } })
Assert.eq(done_n, 0, "队列未走完不回调")
done_fake.step()
Assert.eq(done_n, 1, "队列走完回调一次")

-- cancel 后不再前进
local cancel_fake = newFake()
local cancel_fetched = 0
local cancel_bf = Backfill.new{
    schedule = cancel_fake.schedule,
    fetch = function(_, cb)
        cancel_fetched = cancel_fetched + 1
        cb({})
        return { cancel = function() end }
    end,
    on_success = function() end,
}
cancel_bf:run({ { stable_id = "1", ts = "t" }, { stable_id = "2", ts = "t" } })
Assert.eq(cancel_fetched, 1)
cancel_bf:cancel()
cancel_fake.step()
Assert.eq(cancel_fetched, 1)

-- ── 源级接线：reconcile 后补全 + lastChapterAddedUtc 增量 + 状态落盘 ──

local sched = { delays = {}, queue = {} }
function sched:scheduleIn(delay, fn)
    self.delays[#self.delays + 1] = delay
    self.queue[#self.queue + 1] = { fn = fn, cancelled = false }
end
function sched:unschedule(fn)
    for _, entry in ipairs(self.queue) do
        if entry.fn == fn then entry.cancelled = true end
    end
end
function sched:drain()
    while #self.queue > 0 do
        local entry = table.remove(self.queue, 1)
        if not entry.cancelled then entry.fn() end
    end
end

package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn) fn() end,
        scheduleIn = function(_, delay, fn) sched:scheduleIn(delay, fn) end,
        unschedule = function(_, fn) sched:unschedule(fn) end,
    }
end

local cfg = { base_url = "https://host:port/kavita", api_key = "test-key", libraries = { ["8"] = true } }
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end

local series_db = {
    { id = 1, name = "Book A", libraryName = "L", format = 3, lastChapterAddedUtc = "t1" },
    { id = 2, name = "Book B", libraryName = "L", format = 3, lastChapterAddedUtc = "t2" },
}
local metadata_requests = {}
package.preload["http.request"] = function()
    return {
        request = function(opts, cb)
            local url = opts.url or ""
            if url:match("/api/Series/all%-v2") then
                local page = tonumber(url:match("pageNumber=(%d+)")) or 1
                if page == 1 then
                    cb({ code = 200, body = JsonStub.encode(series_db) })
                else
                    cb({ code = 200, body = "[]" })
                end
            elseif url:match("/api/Series/metadata") then
                local sid = url:match("seriesId=(%d+)")
                metadata_requests[#metadata_requests + 1] = sid
                cb({
                    code = 200,
                    body = JsonStub.encode({
                        seriesId = tonumber(sid),
                        summary = "S" .. sid,
                        writers = { { name = "W" .. sid } },
                    }),
                })
            else
                cb({ code = 404, body = "" })
            end
            return { cancel = function() end }
        end,
    }
end

local remembers = {}
package.preload["book.store"] = function()
    return {
        reconcile = function(_, books)
            return { pulled = #books, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
        end,
        rememberMany = function(books) remembers[#remembers + 1] = books end,
        markDeleted = function() return true end,
    }
end

os.remove(require("utils.paths").root() .. "/kavita-backfill.json")

local Kavita = require("source.kavita")
local source = Kavita.new()

local result
source:syncBooksAsync({}, function(res) result = res end)
sched:drain()

Assert.not_nil(result)
Assert.eq(result.pulled, 2)
Assert.len(metadata_requests, 2)
Assert.len(remembers, 2)
Assert.eq(remembers[1][1].stable_id, "1")
Assert.eq(remembers[1][1].intro, "S1")
Assert.eq(remembers[1][1].authors, "W1")

-- 第二次同步：只有 lastChapterAddedUtc 变过的 series 重拉
series_db[2].lastChapterAddedUtc = "t2b"
metadata_requests = {}
source:syncBooksAsync({}, function() end)
sched:drain()
Assert.len(metadata_requests, 1)
Assert.eq(metadata_requests[1], "2")
