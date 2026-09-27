--[[--
db.stats：云端单书累计 / 单书按日 / 账户日桶与本地逐页记录的合并口径，真实 sqlite 执行。

规则：有云端值 = 云端 + 本地（未上传 或 拉取之后才读）；否则只有本地。

@module tests.db.stats_book_total_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/stats_book_total_spec.sqlite3"
for _, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return db_path end,
        ensureSettings = function() end,
        sanitizeSourceId = function(id) return id end,
    }
end
for _, name in ipairs({ "db.base", "db.stats" }) do package.loaded[name] = nil end

local Base = require("db.base")
local StatsDB = require("db.stats")
local WStats = require("source.wechat.stats")
Assert.not_nil(Base.open())

local D0 = os.time({ year = 2026, month = 9, day = 26, hour = 0 })
local D1 = D0 + 86400
local T1 = D1 + 12 * 3600
local YMD0, YMD1 = os.date("%Y-%m-%d", D0), os.date("%Y-%m-%d", D1)

local function page(source_id, stable_id, start_time, duration, synced)
    Assert.is_true(StatsDB.add({
        source_id = source_id, stable_id = stable_id, record_type = "page",
        page = 7, start_time = start_time, duration = duration, total_pages = 100,
    }, synced))
end

--- 走真实入库路径：mapper → replaceSynced。
local function pull(annual_days, books, fetched_at)
    local result = WStats.fromWires("wechat", {},
        annual_days and { { baseTime = D0, dailyReadTimes = annual_days } } or {},
        nil, books, fetched_at)
    Assert.not_nil(StatsDB.replaceSynced("wechat", result.replace, result.rows))
end

local function byYmd(rows)
    local out = {}
    for _, row in ipairs(rows) do out[row.ymd] = row.seconds end
    return out
end

-- 本地：D0 已上传 100（快照前）、D1 未上传 50、D1 快照后已上传 30
page("wechat", "42", D0 + 3600, 100, true)
page("wechat", "42", D1 + 3600, 50, false)
page("wechat", "42", T1 + 3600, 30, true)

-- 无云端：全本地
Assert.eq(StatsDB.summaryByBook("wechat", "42").total_seconds, 180)
Assert.eq(byYmd(StatsDB.dailyByBook("wechat", "42", 30))[YMD0], 100)

pull({ [tostring(D1)] = 195 }, {
    { id = "42", reading_time = 2578, wire = { readDetail = { data = {
        { readDate = D0, readTime = 440 }, { readDate = D1, readTime = 134 },
    } } } },
    { id = "phone_only", reading_time = 300, wire = { readDetail = { data = {
        { readDate = D0, readTime = 300 },
    } } } },
}, T1)

-- 单书累计：快照 + 未上传 50 + 快照后 30；快照前已上传的 100 已含在快照里
Assert.eq(StatsDB.summaryByBook("wechat", "42").total_seconds, 2578 + 50 + 30)
Assert.eq(StatsDB.summaryByBook("wechat", "42").pages, 3, "页数只数本地逐页记录")
Assert.eq(StatsDB.summaryByBook("wechat", "phone_only").total_seconds, 300)

-- 单书按日：D0 以云端 440 为准（本地 100 已含），D1 = 134 + 50 + 30
local daily = StatsDB.dailyByBook("wechat", "42", 30)
Assert.len(daily, 2)
Assert.eq(daily[1].ymd, YMD1, "最近在前")
Assert.eq(daily[1].seconds, 214)
Assert.eq(daily[2].seconds, 440)
Assert.len(StatsDB.dailyByBook("wechat", "42", 1), 1)
Assert.eq(byYmd(StatsDB.dailyByBook("wechat", "phone_only", 30))[YMD0], 300,
    "只在其他设备读过的书也有按日时长")

-- 洞察当日书单：只有云端的书页坐标为 0
local found
for _, row in ipairs(StatsDB.dailyBooksBySource("wechat")) do
    if row.stable_id == "phone_only" then found = row end
end
Assert.eq(found.ymd, YMD0)
Assert.eq(found.seconds, 300)
Assert.eq(found.max_total_pages, 0)

-- 账单：书单与书数含其他设备读过的书
local books = StatsDB.periodBooks("wechat", D0, D1 + 86400, 5)
Assert.len(books, 2)
Assert.eq(books[1].stable_id, "42")
Assert.eq(books[1].seconds, 440 + 214)
Assert.eq(books[2].stable_id, "phone_only")
local period = StatsDB.periodSummary("wechat", D0, D1 + 86400)
Assert.eq(period.book_count, 2)
Assert.eq(period.pages, 3)

-- 账户日历：D1 云端 195 + 拉取后本地新读 80；D0 无云端日桶 → 本地 100
local account = byYmd(StatsDB.dailyBySource("wechat"))
Assert.eq(account[YMD1], 195 + 50 + 30)
Assert.eq(account[YMD0], 100)
Assert.eq(period.total_seconds, 100 + 275)

-- 再拉一次：整本替换不累加；快照时间后移，T1 后已上传的 30 已含在新快照里
local T2 = D1 + 14 * 3600
pull(nil, { { id = "42", reading_time = 2700, wire = { readDetail = { data = {
    { readDate = D1, readTime = 500 },
} } } } }, T2)
Assert.eq(StatsDB.summaryByBook("wechat", "42").total_seconds, 2700 + 50)
local again = byYmd(StatsDB.dailyByBook("wechat", "42", 30))
Assert.eq(again[YMD1], 500 + 50)
Assert.eq(again[YMD0], 100, "旧云端日明细被整本替换掉，回落本地")
Assert.eq(StatsDB.summaryByBook("wechat", "phone_only").total_seconds, 300, "其他书不受影响")

-- 按书精确替换：书 id 互为前缀也不误删
pull(nil, { { id = "4", reading_time = 60, wire = {} } }, T2)
Assert.eq(StatsDB.summaryByBook("wechat", "42").total_seconds, 2750)
Assert.eq(StatsDB.summaryByBook("wechat", "4").total_seconds, 60)

-- 云端累计清零：旧快照与明细一并清掉，回落本地
pull(nil, { { id = "phone_only", reading_time = 0, wire = {} } }, T2)
Assert.eq(StatsDB.summaryByBook("wechat", "phone_only").total_seconds, 0)
Assert.len(StatsDB.dailyByBook("wechat", "phone_only", 30), 0)

-- 旧版拉取的日桶没有 last_time：只补未上传的，已上传的不再加（宁可少算不双计）
Assert.is_true(StatsDB.add({
    source_id = "legacy", stable_id = "__wr:day:" .. D1, record_type = "day",
    page = 0, start_time = D1, duration = 600, total_pages = 0,
}, true))
page("legacy", "b", D1 + 3600, 40, true)
page("legacy", "b", D1 + 7200, 20, false)
Assert.eq(byYmd(StatsDB.dailyBySource("legacy"))[YMD1], 620)

-- 账户级统计拉取的区间清理（只删 day/book/total）不碰单书明细
pull({ [tostring(D1)] = 195 }, nil, T2)
Assert.eq(StatsDB.summaryByBook("wechat", "42").total_seconds, 2750)
Assert.eq(byYmd(StatsDB.dailyByBook("wechat", "42", 30))[YMD1], 550)

Base.close()
for _, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
