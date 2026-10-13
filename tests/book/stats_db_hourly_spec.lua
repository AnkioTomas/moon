--[[--
book.stats_db：hourlyBySource 按本地日期 × 小时汇总本机记录（压缩行落在原小时，云端日桶不算）；
summaryByBook.first_read 取本机记录与云端单书日桶里最早的一条。真实 sqlite 执行。

@module tests.book.stats_db_hourly_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/stats_hourly_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return db_path end,
        ensureSettings = function() end,
        sanitizeSourceId = function(id) return id end,
    }
end
package.loaded["utils.settings"] = nil
package.preload["utils.settings"] = function()
    return { getSource = function() return {} end }
end
for _idx, name in ipairs({ "utils.db", "book.stats_db" }) do package.loaded[name] = nil end

local Base = require("utils.db")
local StatsDB = require("book.stats_db")
Assert.not_nil(Base.open())

local function add(source_id, stable_id, record_type, start_time, duration)
    Assert.is_true(StatsDB.add({ source_id = source_id, stable_id = stable_id, record_type = record_type,
        page = 1, start_time = start_time, duration = duration, total_pages = 0 }, StatsDB.SYNCED))
end

local DAY = os.time({ year = 2026, month = 10, day = 10, hour = 0 })
add("local", "a", "page", DAY + 21 * 3600 + 100, 60)
add("local", "a", "page", DAY + 21 * 3600 + 900, 30)
add("local", "a", "page_rollup", DAY + 8 * 3600, 600)
add("wechat", "w", "page", DAY + 8 * 3600 + 5, 40)
add("wechat", "w", "book_day", DAY - 86400 * 3, 3600)
add("wechat", "w", "day", DAY - 86400 * 3, 3600)

local hourly = StatsDB.hourlyBySource("local")
local hours = hourly["2026-10-10"]
Assert.eq(hours[22], 90, "21 点两条合到一格")
Assert.eq(hours[9], 600, "压缩行落在原小时")
Assert.eq(hours[1], 0)
Assert.len(hours, 24)

local mixed = StatsDB.hourlyBySource({ "local", "wechat" })
Assert.eq(mixed["2026-10-10"][9], 640, "多源按格相加")
Assert.is_nil(mixed["2026-10-07"], "云端日桶不知道几点读的，不算")

Assert.eq(StatsDB.summaryByBook("local", "a").first_read, DAY + 8 * 3600)
Assert.eq(StatsDB.summaryByBook("wechat", "w").first_read, DAY - 86400 * 3, "云端单书日桶也算开始日期")
Assert.eq(StatsDB.summaryByBook("local", "none").first_read, 0)

Base.close()
