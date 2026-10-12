--[[--
book.stats_db：merge_local_stats 打开时按天取云端与本地较大值，补上离线阅读；关闭时云端优先。真实 sqlite 执行。

@module tests.book.stats_db_merge_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/stats_merge_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return db_path end,
        ensureSettings = function() end,
        sanitizeSourceId = function(id) return id end,
    }
end
local cfg = {}
package.loaded["utils.settings"] = nil
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end
for _idx, name in ipairs({ "utils.db", "book.stats_db", "source.wechat.stats" }) do package.loaded[name] = nil end

local Base = require("utils.db")
local StatsDB = require("book.stats_db")
local WStats = require("source.wechat.stats")
Assert.not_nil(Base.open())

local DAY = os.time({ year = 2026, month = 10, day = 10, hour = 0 })
local PREV = DAY - 86400
local FETCHED = DAY + 22 * 3600

local function page(start_time, duration)
    Assert.is_true(StatsDB.add({ source_id = "wechat", stable_id = "b1", record_type = "page",
        page = 1, start_time = start_time, duration = duration, total_pages = 9, chapter_idx = 1 }, true))
end

-- 上午在线读 1:35 已被心跳报上；下午离线读 2 小时云端没有；前一天离线读 10 分钟；拉取后又读 100 秒。
page(DAY + 9 * 3600, 5700)
page(DAY + 14 * 3600, 7200)
page(PREV + 10 * 3600, 600)
local result = WStats.fromWires("wechat", { totalReadTime = 5700 }, {},
    { { readTimes = { [tostring(DAY)] = 5700 } } }, {}, FETCHED)
Assert.not_nil(StatsDB.replaceSynced("wechat", result.replace, result.rows))
page(FETCHED + 3600, 100)

local function day(ymd)
    for _idx, row in ipairs(StatsDB.dailyBySource("wechat")) do
        if row.ymd == ymd then return row.seconds end
    end
end

-- 云端优先（默认）：有日桶的日期 = 云端 + 拉取后新读；总时长 = 云端 total + 拉取后新读。
Assert.eq(StatsDB.summaryBySource("wechat").total_seconds, 5700 + 100)
Assert.eq(day("2026-10-10"), 5700 + 100)
Assert.eq(day("2026-10-09"), 600, "没有云端日桶的日期本来就用本地")

-- 合并：当天取较大值，离线的 2 小时和前一天的 10 分钟都补进总时长，在线那段不双计。
cfg.merge_local_stats = true
Assert.eq(day("2026-10-10"), 5700 + 7200 + 100)
Assert.eq(day("2026-10-09"), 600)
Assert.eq(StatsDB.summaryBySource("wechat").total_seconds, 5700 + 7200 + 600 + 100)

-- 云端比本地多（挂机不翻页心跳照报）时仍用云端，不往下压。
cfg.merge_local_stats = true
Assert.is_true(Base.exec("UPDATE reading_stats SET duration=20000 WHERE record_type='day';") ~= nil)
Assert.eq(day("2026-10-10"), 20000 + 100)

Base.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
