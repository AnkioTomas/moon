--[[--
book.stats_db：WebDAV 拉取把远端汇总行写成 page_rollup，与本地 30 天压缩共存，真实 sqlite 执行。

@module tests.book.stats_db_rollup_pull_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/stats_rollup_pull_spec.sqlite3"
for _, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return db_path end,
        ensureSettings = function() end,
        sanitizeSourceId = function(id) return id end,
    }
end
for _, name in ipairs({ "utils.db", "book.stats_db" }) do package.loaded[name] = nil end

local Base = require("utils.db")
local StatsDB = require("book.stats_db")
Assert.not_nil(Base.open())

local clock = os.date("*t", os.time() - 40 * 86400)
clock.min, clock.sec = 0, 0
local OLD = os.time(clock)
local NOW = os.time() - 600
local ID = "webdav://a.epub"

-- 本地：上一轮压出的已同步汇总行（同一小时）、一条未上传的新页。
Assert.is_true(StatsDB.add({ source_id = "local", stable_id = ID, record_type = "page_rollup",
    page = 5, start_time = OLD, duration = 70, total_pages = 9, event_count = 2, last_time = OLD + 120 }, true))
Assert.is_true(StatsDB.add({ source_id = "local", stable_id = ID, record_type = "page",
    page = 9, start_time = NOW + 60, duration = 12, total_pages = 9 }))

-- 拉取：全量覆盖已同步行，远端同一小时的汇总写回 page_rollup，不撞 书+小时 唯一索引。
local saved = StatsDB.replaceSynced("local", { mode = "all_synced" }, {
    { source_id = "local", stable_id = ID, record_type = "page_rollup", page = 7, start_time = OLD,
        duration = 140, total_pages = 9, event_count = 5, last_time = OLD + 1800 },
    { source_id = "local", stable_id = ID, record_type = "page", page = 6, start_time = NOW,
        duration = 10, total_pages = 9 },
})
Assert.not_nil(saved)
Assert.eq(saved.imported, 2)
Assert.eq(StatsDB.summaryByBook("local", ID).total_seconds, 140 + 10 + 12, "汇总行替换旧汇总，未上传的不丢")

-- 本地压缩：远端已压过，没有老逐页行可压。
Assert.eq(StatsDB.compactSynced("local", os.time() - 30 * 86400, 1000), 0)

-- 再拉同一份：整表替换不累加。
Assert.not_nil(StatsDB.replaceSynced("local", { mode = "all_synced" }, {
    { source_id = "local", stable_id = ID, record_type = "page_rollup", page = 7, start_time = OLD,
        duration = 140, total_pages = 9, event_count = 5, last_time = OLD + 1800 },
    { source_id = "local", stable_id = ID, record_type = "page", page = 6, start_time = NOW,
        duration = 10, total_pages = 9 },
}))
Assert.eq(StatsDB.summaryByBook("local", ID).total_seconds, 162)

-- 按书拉取：只覆盖列出的书；别的书的已同步行不动，列出的书本批为空也清掉已同步行，未上传的不丢。
local OTHER = "webdav://b.epub"
Assert.is_true(StatsDB.add({ source_id = "local", stable_id = OTHER, record_type = "page",
    page = 1, start_time = NOW, duration = 20, total_pages = 9 }, true))
Assert.not_nil(StatsDB.replaceSynced("local", { mode = "synced_books", stable_ids = { ID } }, {}))
Assert.eq(StatsDB.summaryByBook("local", ID).total_seconds, 12)
Assert.eq(StatsDB.summaryByBook("local", OTHER).total_seconds, 20)
Assert.not_nil(StatsDB.replaceSynced("local", { mode = "synced_books", stable_ids = { ID, OTHER } }, {
    { source_id = "local", stable_id = ID, record_type = "page", page = 6, start_time = NOW,
        duration = 10, total_pages = 9 },
}))
Assert.eq(StatsDB.summaryByBook("local", ID).total_seconds, 22)
Assert.eq(StatsDB.summaryByBook("local", OTHER).total_seconds, 0)

Base.close()
for _, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
