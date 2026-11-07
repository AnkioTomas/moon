--[[--
豆瓣阅读时长：秒级账户快照、日期窗口、重复同步和本地未上传时长。

@module tests.source.douban.stats_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
package.preload["json"] = function() return require("support.json_stub") end
local Mapper = require("source.douban.mapper")
local StatsDB = require("book.stats_db")
local now = os.time({ year = 2026, month = 11, day = 7, hour = 15 })
local wire = { data = { user = {
    readingTimeTotal = { duration = 7200, normalDuration = 6000, textToSpeechDuration = 1200 },
    readingTimeHistory = {
        { date = "2026-11-06", readingTime = { duration = 600 } },
        { date = "2026-11-07", readingTime = { duration = 1200 } },
    },
} } }
local snapshot = Mapper.readingStats(wire, "2026-10-09", now)
Assert.eq(#snapshot.rows, 3)
Assert.eq(snapshot.rows[1].record_type, "total")
Assert.eq(snapshot.rows[1].duration, 7200)
Assert.eq(snapshot.rows[1].event_count, 0)
Assert.eq(snapshot.rows[2].duration, 600)
Assert.is_nil(Mapper.readingStats({ errors = { { message = "failed" } } }, "2026-10-09", now))
wire.errors = { { message = "partial response" } }
Assert.is_nil(Mapper.readingStats(wire, "2026-10-09", now))
wire.errors = nil
wire.data.user.readingTimeHistory[2].date = "2026-02-30"
Assert.is_nil(Mapper.readingStats(wire, "2026-10-09", now))
wire.data.user.readingTimeHistory[2].date = "2026-11-06"
Assert.is_nil(Mapper.readingStats(wire, "2026-10-09", now))
wire.data.user.readingTimeHistory[2].date = "2026-11-07"
wire.data.user.readingTimeHistory[2].readingTime.duration = -1
Assert.is_nil(Mapper.readingStats(wire, "2026-10-09", now))
wire.data.user.readingTimeHistory[2].readingTime.duration = 1200

Assert.is_true(StatsDB.removeSource("douban"))
Assert.is_true(StatsDB.add({
    source_id = "douban", stable_id = "test-book", record_type = "page",
    start_time = now - 600, duration = 60, page = 1, total_pages = 10,
}, StatsDB.PENDING))
Assert.is_true(StatsDB.replaceSynced("douban", snapshot.replace, snapshot.rows) ~= nil)
Assert.eq(StatsDB.summaryBySource("douban").total_seconds, 7260)
Assert.eq(StatsDB.dailyBySource("douban")[2].seconds, 1260)
Assert.eq(#StatsDB.unsyncedBySource("douban", 200), 1)
Assert.is_true(StatsDB.replaceSynced("douban", snapshot.replace, snapshot.rows) ~= nil)
Assert.eq(StatsDB.summaryBySource("douban").total_seconds, 7260)
wire.data.user.readingTimeHistory[1].readingTime.duration = 0
snapshot = Mapper.readingStats(wire, "2026-10-09", now)
Assert.is_true(StatsDB.replaceSynced("douban", snapshot.replace, snapshot.rows) ~= nil)
Assert.eq(#StatsDB.dailyBySource("douban"), 1)
Assert.eq(StatsDB.summaryBySource("douban").total_pages, 1)

local request
package.preload["utils.settings"] = function()
    return { getSource = function() return { cookie = "session=test", logged_in = true, user_id = "42" } end }
end
package.preload["http.request"] = function()
    return {
        headerAll = function() return {} end,
        request = function(opts, cb)
            request = opts
            if opts.method == "GET" then cb({ code = 200, body = "CSRF_TOKEN = 'test';" })
            else cb({ code = 200, body = require("support.json_stub").encode(wire) }) end
            return { cancel = function() end }
        end,
    }
end
local source = require("source.douban").new()
package.loaded["utils.settings"] = nil
Assert.eq(source:capabilities().stats_pull, true)
local result
source:pullStatsAsync(function(value) result = value end)
Assert.is_true(result ~= nil)
local payload = require("support.json_stub").decode(request.body)
Assert.eq(payload.variables.userId, "42")
Assert.is_true(payload.variables.beginDate:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil)
Assert.eq(request.headers["X-CSRF-Token"], "test")
Assert.eq(payload.extensions.persistedQuery.sha256Hash, Mapper.READING_TIME_HASH)
StatsDB.removeSource("douban")
