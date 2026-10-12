--[[--
book.stats_db：微信权威累计 total 与拉取后本地新读时长合并，真实 sqlite 执行。

@module tests.book.stats_db_total_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/stats_total_spec.sqlite3"
for _, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return db_path end,
        ensureSettings = function() end,
        sanitizeSourceId = function(id) return id end,
    }
end
for _, name in ipairs({ "utils.db", "book.stats_db", "source.wechat.stats" }) do package.loaded[name] = nil end

local Base = require("utils.db")
local StatsDB = require("book.stats_db")
local WStats = require("source.wechat.stats")
Assert.not_nil(Base.open())

local FETCHED = os.time() - 3600
local ID = "book-1"

local function pull(total, fetched_at)
    local result = WStats.fromWires("wechat", { totalReadTime = total }, {}, {}, {}, fetched_at)
    Assert.not_nil(StatsDB.replaceSynced("wechat", result.replace, result.rows))
end

local function page(start_time, duration, synced)
    Assert.is_true(StatsDB.add({ source_id = "wechat", stable_id = ID, record_type = "page",
        page = 1, start_time = start_time, duration = duration, total_pages = 9, chapter_idx = 1 }, synced))
end

-- 拉取前已上传的已含在快照里；拉取后读的（已上传或未上传）都要补上。
page(FETCHED - 600, 50, true)
pull(7200, FETCHED)
Assert.eq(StatsDB.summaryBySource("wechat").total_seconds, 7200)
page(FETCHED + 60, 30, false)
page(FETCHED + 120, 40, true)
Assert.eq(StatsDB.summaryBySource("wechat").total_seconds, 7200 + 30 + 40, "总时长随本地新读增长")

-- 先推后拉：新快照已含之前读的，替换旧 total、不累加。
Assert.is_true(Base.exec("UPDATE reading_stats SET sync_status=1 WHERE record_type='page';") ~= nil)
pull(7300, FETCHED + 600)
Assert.eq(StatsDB.summaryBySource("wechat").total_seconds, 7300)

-- 旧版拉取没记拉取时间：只补未上传的，宁可少算也不双计。
Assert.is_true(Base.exec("UPDATE reading_stats SET last_time=0 WHERE record_type='total';") ~= nil)
page(FETCHED + 900, 20, false)
Assert.eq(StatsDB.summaryBySource("wechat").total_seconds, 7300 + 20)

Base.close()
for _, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
