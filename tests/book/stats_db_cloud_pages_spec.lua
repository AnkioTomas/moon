--[[--
book.stats_db：漫画云端会话的页数（cloud_session 的 event_count / total_pages）参与聚合，
且不把已经上报过的本地页再数一遍。真实 sqlite 执行。

口径（18 号票）：
  - summaryByBook.pages = 云端会话 event_count + 未被会话覆盖的本地页；
    本地页行上报成功后已包含在云端会话里，套 FRESH_LOCAL 才不双计；
  - summaryByBook.total_pages = 云端与本地两侧 MAX（卷级总页数）；
  - bookDays / dailyByBook 的逐日 pages 同样含会话页数，只叠 fresh 的本地页；
  - 没有会话行的来源（微信 / moon / WebDAV 只回逐页行）照旧数本地页，不能因为本次改动清零。

@module tests.book.stats_db_cloud_pages_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/stats_cloud_pages_spec.sqlite3"
for _, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
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
for _, name in ipairs({ "utils.db", "book.stats_db" }) do package.loaded[name] = nil end

local Base = require("utils.db")
local StatsDB = require("book.stats_db")
Assert.not_nil(Base.open())

local SRC = "kavita"
local DAY = os.time({ year = 2026, month = 10, day = 20, hour = 0 })
local PREV = DAY - 86400
local FETCHED = DAY + 20 * 3600

local function add(row, status)
    Assert.is_true(StatsDB.add(row, status or StatsDB.SYNCED))
end

local function cloud_session(stable_id, start_time, duration, pages, page, total_pages)
    return {
        source_id = SRC, stable_id = stable_id, record_type = "cloud_session",
        page = page or 0, start_time = start_time, duration = duration,
        total_pages = total_pages or 0, event_count = pages or 0, last_time = start_time,
    }
end

local function local_page(source_id, stable_id, start_time, duration, pages, total_pages)
    return {
        source_id = source_id, stable_id = stable_id, record_type = "page",
        page = 15, start_time = start_time, duration = duration,
        total_pages = total_pages or 194, event_count = pages,
    }
end

-- C1：漫画，同一天既有云端会话，也有上报过的本地页（量相同，不能再数一遍），
-- 还有拉取时间之后新读的本地页（要叠上去）。
add(cloud_session("C1", DAY + 10 * 3600, 300, 12, 15, 194))
add(local_page(SRC, "C1", DAY + 10 * 3600 + 60, 300, 12), StatsDB.SYNCED) -- 已上报 → 在会话里
add(cloud_session("C1", PREV + 9 * 3600, 200, 8, 120, 194)) -- 另一天只有云端会话
add(local_page(SRC, "C1", DAY + 21 * 3600, 120, 5), StatsDB.PENDING) -- 未上传
add(local_page(SRC, "C1", DAY + 22 * 3600, 60, 3), StatsDB.SYNCED) -- 拉取之后才读
for _idx, day in ipairs({ DAY, PREV }) do
    add({ source_id = SRC, stable_id = "C1", record_type = "book_day", page = 0, start_time = day,
        duration = day == DAY and 300 or 200, total_pages = 0, last_time = FETCHED })
end
add({ source_id = SRC, stable_id = "C1", record_type = "book_total", page = 0,
    start_time = FETCHED, duration = 500, total_pages = 0, last_time = FETCHED })

-- C2：只有云端会话（本机没逐页记录），且 pagesRead = 0（打开没翻页）——0 是合法值。
add(cloud_session("C2", DAY + 8 * 3600, 100, 0, 3, 50))
add({ source_id = SRC, stable_id = "C2", record_type = "book_day", page = 0, start_time = DAY,
    duration = 100, total_pages = 0, last_time = FETCHED })

-- C3：只有云端会话，两条 -> 页数相加、总页数取 MAX。
add(cloud_session("C3", DAY + 9 * 3600, 60, 4, 10, 40))
add(cloud_session("C3", PREV + 9 * 3600, 60, 6, 25, 60))
for _idx, day in ipairs({ DAY, PREV }) do
    add({ source_id = SRC, stable_id = "C3", record_type = "book_day", page = 0, start_time = day,
        duration = 60, total_pages = 0, last_time = FETCHED })
end

-- W1：微信这类只回逐页行、没有 cloud_session 的来源：已同步的本地页照旧要数。
add(local_page("wechat", "W1", DAY + 3600, 100, 3), StatsDB.SYNCED)
add(local_page("wechat", "W1", DAY + 7200, 100, 4), StatsDB.SYNCED)

-- 单书：会话页数 + 拉取后 / 未上传的本地页；上报过的本地页已在会话里，不再加。
local s1 = StatsDB.summaryByBook(SRC, "C1")
Assert.eq(s1.pages, 12 + 8 + 5 + 3, "会话 event_count 之和 + fresh 本地页")
Assert.eq(s1.total_pages, 194, "总页数取云端与本地两侧 MAX")
Assert.eq(s1.total_seconds, 500 + 120 + 60, "会话时长不复计（累计快照已含）")

-- 只有云端会话时：页数 = 各会话 event_count 之和，总页数 = MAX。
local s3 = StatsDB.summaryByBook(SRC, "C3")
Assert.eq(s3.pages, 10)
Assert.eq(s3.total_pages, 60)
Assert.eq(StatsDB.summaryByBook(SRC, "C2").pages, 0, "pagesRead = 0 的会话不凭空加一页")
Assert.eq(StatsDB.summaryByBook(SRC, "C2").total_pages, 50)

-- 没有会话的来源不被清零（回归：本地已同步页仍按全量计）。
local w1 = StatsDB.summaryByBook("wechat", "W1")
Assert.eq(w1.pages, 7, "没有 cloud_session 的来源照旧数本地页")

-- 逐日：云端会话按天计页，只叠 fresh 的本地页。
local days = StatsDB.dailyByBook(SRC, "C1", 30)
Assert.len(days, 2)
Assert.eq(days[1].ymd, os.date("%Y-%m-%d", DAY))
Assert.eq(days[1].seconds, 300 + 120 + 60)
Assert.eq(days[1].pages, 12 + 5 + 3, "已上报的本地页在会话里，不双计")
Assert.eq(days[2].ymd, os.date("%Y-%m-%d", PREV))
Assert.eq(days[2].seconds, 200)
Assert.eq(days[2].pages, 8, "本机没读的那天也计云端会话页数")

-- 多卷容器：各卷逐身份相加，页数同理。
add(cloud_session("C4:v1", DAY + 10 * 3600, 60, 4, 10, 40))
add(cloud_session("C4:v2", DAY + 11 * 3600, 60, 6, 25, 60))
for _idx, id in ipairs({ "C4:v1", "C4:v2" }) do
    add({ source_id = SRC, stable_id = id, record_type = "book_day", page = 0, start_time = DAY,
        duration = 60, total_pages = 0, last_time = FETCHED })
end
local books = StatsDB.summaryByBooks(SRC, { "C4:v1", "C4:v2" })
Assert.eq(books.pages, 10)
Assert.eq(books.total_pages, 100, "多卷容器总页数沿用逐卷相加")

-- 逐日多卷：同一天各卷相加。
local multi_days = StatsDB.dailyByBooks(SRC, { "C4:v1", "C4:v2" }, 30)
Assert.len(multi_days, 1)
Assert.eq(multi_days[1].pages, 10)

Base.close()
for _, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
