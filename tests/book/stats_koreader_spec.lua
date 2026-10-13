--[[--
book.stats_koreader：KOReader 统计库按 md5 / 唯一书名对书导入，本插件已覆盖的分钟不导入，
导入行记为已同步，重复导入不重复计。真实 sqlite 执行。

@module tests.book.stats_koreader_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local sqlite_ok, SQL = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/stats_koreader_spec.sqlite3"
local ko_path = Config.dir() .. "/stats_koreader_spec_ko.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do
    os.remove(db_path .. suffix)
    os.remove(ko_path .. suffix)
end

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
package.loaded["util"] = { partialMD5 = function() return nil end }
for _idx, name in ipairs({ "utils.db", "utils.event", "book.books_db", "book.chapters_db",
    "book.stats_db", "book.stats_koreader" }) do
    package.loaded[name] = nil
end

local Base = require("utils.db")
local BookDB = require("book.books_db")
local StatsDB = require("book.stats_db")
local KoreaderStats = require("book.stats_koreader")
Assert.not_nil(Base.open())

local function book(source_id, stable_id, md5, title)
    Assert.is_true(BookDB.upsert({ source_id = source_id, stable_id = stable_id, md5 = md5, title = title }))
end
book("local", "/b/a.epub", "aaa", "甲")
book("wechat", "w1", nil, "乙")
book("local", "/b/c.epub", "ccc", "重名")
book("local", "/b/d.epub", "ddd", "重名")

local T = 1700000040 -- 整分钟
local H = 1700002800 -- 整小时
-- 本插件读 a.epub 时自己记了一页（未同步）；w1 在 H 这一小时有压缩行。
Assert.is_true(StatsDB.add({ source_id = "local", stable_id = "/b/a.epub", record_type = "page",
    page = 3, start_time = T, duration = 30, total_pages = 100 }))
Assert.is_true(StatsDB.add({ source_id = "wechat", stable_id = "w1", record_type = "page_rollup",
    page = 5, start_time = H, duration = 900, total_pages = 50 }, StatsDB.SYNCED))

local ko = SQL.open(ko_path)
ko:exec([[
CREATE TABLE book (id integer PRIMARY KEY autoincrement, title text, authors text, notes integer,
  last_open integer, highlights integer, pages integer, series text, language text, md5 text,
  total_read_time integer, total_read_pages integer);
CREATE TABLE page_stat_data (id_book integer, page integer NOT NULL DEFAULT 0,
  start_time integer NOT NULL DEFAULT 0, duration integer NOT NULL DEFAULT 0,
  total_pages integer NOT NULL DEFAULT 0, UNIQUE (id_book, page, start_time));
INSERT INTO book (id, title, md5) VALUES (1, '别名', 'aaa');
INSERT INTO book (id, title, md5) VALUES (2, ' 乙 ', 'zzz');
INSERT INTO book (id, title, md5) VALUES (3, '重名', 'yyy');
INSERT INTO book (id, title, md5) VALUES (4, '无', 'qqq');
INSERT INTO book (id, title, md5) VALUES (5, '没读', 'aaa');
]])
ko:exec(string.format([[
INSERT INTO page_stat_data VALUES (1, 3, %d, 20, 100);
INSERT INTO page_stat_data VALUES (1, 4, %d, 60, 100);
INSERT INTO page_stat_data VALUES (1, 5, %d, 0, 100);
INSERT INTO page_stat_data VALUES (2, 5, %d, 30, 50);
INSERT INTO page_stat_data VALUES (2, 6, %d, 45, 50);
INSERT INTO page_stat_data VALUES (3, 1, %d, 10, 10);
INSERT INTO page_stat_data VALUES (4, 1, %d, 10, 10);
]], T + 10, T + 600, T + 900, H + 100, H + 3700, T, T))
ko:close()

Assert.eq(select(2, KoreaderStats.import(Config.dir() .. "/nope.sqlite3")), "missing")

local counts = KoreaderStats.import(ko_path)
Assert.eq(counts.books, 2, "md5 对上甲、书名对上乙")
Assert.eq(counts.rows, 2, "与本插件记录同一分钟的、时长 0 的都不导入")
Assert.eq(counts.unmatched, 2, "书名重复与对不上的跳过；没有记录的书不计")

Assert.eq(StatsDB.summaryByBook("local", "/b/a.epub").total_seconds, 30 + 60)
Assert.eq(StatsDB.summaryByBook("wechat", "w1").total_seconds, 900 + 45)
Assert.eq(StatsDB.summaryByBook("local", "/b/c.epub").total_seconds, 0)
Assert.eq(#StatsDB.unsyncedBySource("local"), 1, "导入行记为已同步，不推给源")
Assert.eq(#StatsDB.unsyncedBySource("wechat"), 0)

counts = KoreaderStats.import(ko_path)
Assert.eq(counts.rows, 0, "重复导入不重复计")
Assert.eq(counts.books, 0)
Assert.eq(StatsDB.summaryByBook("local", "/b/a.epub").total_seconds, 90)

-- 压缩后再导入仍不重复：压缩行按整小时覆盖。
Assert.not_nil(StatsDB.compactSynced("local", T + 3 * 3600))
Assert.eq(KoreaderStats.import(ko_path).rows, 0)
Assert.eq(StatsDB.summaryByBook("local", "/b/a.epub").total_seconds, 90)

-- 源全量 pull（all_synced）只删已同步行，导入行留着。
Assert.not_nil(StatsDB.replaceSynced("local", { mode = "all_synced" }, {
    { source_id = "local", stable_id = "/b/c.epub", record_type = "page", page = 1,
      start_time = H, duration = 5, total_pages = 10 },
}))
Assert.eq(StatsDB.summaryByBook("local", "/b/a.epub").total_seconds, 90)
Assert.eq(StatsDB.summaryByBook("wechat", "w1").total_seconds, 900 + 45)

Base.close()
