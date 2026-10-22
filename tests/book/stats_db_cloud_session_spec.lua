--[[--
book.stats_db：云端阅读会话（cloud_session）的列表 / 去重 / 替换，以及多卷书统计合并。
真实 sqlite 执行。

规则：
  - cloud_session 只服务详情「阅读记录」与统计页会话列表，不参与任何时长汇总；
  - 本机同一天已有逐页记录时，不再列云端会话（同一次阅读不重复列）；
  - 云端单书行按 replace.books 整本替换（含 cloud_session），旧会话不会残留。

@module tests.book.stats_db_cloud_session_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/stats_cloud_session_spec.sqlite3"
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

local SRC = "ext.kavita"
local DAY = os.time({ year = 2026, month = 10, day = 22, hour = 0 })
local AT = DAY + 17 * 3600 + 54 * 60

local function add(row, status)
    Assert.is_true(StatsDB.add(row, status or StatsDB.SYNCED))
end

local function cloud_session(stable_id, start_time, duration, pages)
    return {
        source_id = SRC, stable_id = stable_id, record_type = "cloud_session",
        page = 0, start_time = start_time, duration = duration, total_pages = 0,
        event_count = pages or 0, last_time = start_time,
    }
end

local function page(stable_id, start_time, duration)
    return {
        source_id = SRC, stable_id = stable_id, record_type = "page", page = 4,
        start_time = start_time, duration = duration, total_pages = 100,
    }
end

-- 本机读过 A（同一天有逐页记录）；B 只有云端会话。
add(page("A", AT, 120), StatsDB.PENDING)
add(cloud_session("A", AT, 120, 4))
add(cloud_session("B", AT + 3600, 600, 12))
add({
    source_id = SRC, stable_id = "B", record_type = "book_total",
    page = 0, start_time = AT + 7200, duration = 600, total_pages = 0, last_time = AT + 7200,
})

-- 会话列表：本机会话（page）在，A 的云端会话被同天本地记录压掉，B 的保留。
local rows = StatsDB.sessionRows(SRC, 0)
Assert.eq(#rows, 2, "page + B 的 cloud_session；A 的重复会话不列")
local seen = {}
for _, row in ipairs(rows) do seen[row.stable_id .. "#" .. row.start_time] = row end
Assert.not_nil(seen["A#" .. AT], "本机逐页会话")
Assert.not_nil(seen["B#" .. (AT + 3600)], "云端会话补本机没有的书")

-- 单书会话：A 当天有本地记录 → 不列云端；B 列出来。
Assert.eq(#StatsDB.sessionsByBook(SRC, "A", 10), 0, "同一天有本机记录不重复列")
local b_sessions = StatsDB.sessionsByBook(SRC, "B", 10)
Assert.eq(#b_sessions, 1)
Assert.eq(b_sessions[1].start_time, AT + 3600)
Assert.eq(b_sessions[1].duration, 600)
Assert.eq(b_sessions[1].pages, 12)

-- 只有云端时长的书：pages=0 但时长 / 上次阅读都要有值（详情页不再显示「暂无阅读记录」）。
local summary = StatsDB.summaryByBook(SRC, "B")
Assert.eq(summary.total_seconds, 600, "累计快照算总时长")
Assert.eq(summary.pages, 0, "云端没有页坐标")
Assert.eq(summary.last_read, AT + 3600, "上次阅读取云端会话时刻")
Assert.eq(summary.first_read, AT + 3600)

-- 多卷书合并：容器详情把各卷的时长 / 页数 / 会话并成一本。
add(cloud_session("S3:v1", AT, 100, 5))
add(cloud_session("S3:v2", AT + 3600, 50, 2))
for _idx, item in ipairs({ { "S3:v1", 100 }, { "S3:v2", 50 } }) do
    add({ source_id = SRC, stable_id = item[1], record_type = "book_day",
        page = 0, start_time = DAY, duration = item[2], total_pages = 0, last_time = AT + 7200 })
    add({ source_id = SRC, stable_id = item[1], record_type = "book_total",
        page = 0, start_time = AT + 7200, duration = item[2], total_pages = 0, last_time = AT + 7200 })
end
local books = StatsDB.summaryByBooks(SRC, { "S3:v1", "S3:v2" })
Assert.eq(books.total_seconds, 150)
Assert.eq(books.pages, 0, "云端会话的页数不进「已读页数」")
Assert.eq(books.last_read, AT + 3600)
local days = StatsDB.dailyByBooks(SRC, { "S3:v1", "S3:v2" }, 30)
Assert.eq(#days, 1, "同一天各卷相加")
Assert.eq(days[1].seconds, 150)
local multi = StatsDB.sessionsByBook(SRC, { "S3:v1", "S3:v2" }, 10)
Assert.eq(#multi, 2, "两卷的会话都列出来")
Assert.eq(multi[1].stable_id, "S3:v2", "按开始时间倒序")

-- 替换：replace.books 整本替换时旧会话一起清掉，回包里没再出现的书不残留。
Assert.is_true(StatsDB.replaceSynced(SRC, {
    mode = "ranges",
    ranges = {},
    books = { "B", "S3:v1", "S3:v2" },
}, { cloud_session("B", AT + 7200, 900, 20) }))
b_sessions = StatsDB.sessionsByBook(SRC, "B", 10)
Assert.eq(#b_sessions, 1, "旧会话被替换")
Assert.eq(b_sessions[1].start_time, AT + 7200)
Assert.eq(b_sessions[1].duration, 900)
Assert.eq(#StatsDB.sessionsByBook(SRC, { "S3:v1", "S3:v2" }, 10), 0, "回包里消失的卷会话不留")

-- 会话行不进账户汇总：账户日桶只认 day 桶 + 本地逐页，book_day / cloud_session 都不会重复累加。
local account_days = StatsDB.dailyBySource(SRC)
Assert.eq(#account_days, 1)
Assert.eq(account_days[1].seconds, 120, "账户当日只有 A 的本机逐页记录")

Base.close()
