--[[--
退出登录清本地记录：整源删除在架行和墓碑，依附表跟着走，别的源不动。
不留墓碑，否则下次登录会把这些书推成远端删除。

@module tests.book.forget_source_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/forget_source_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return db_path end,
        ensureSettings = function() end,
        sanitizeSourceId = function(id) return id end,
    }
end
for _idx, name in ipairs({
    "utils.db", "utils.event", "book.books_db", "book.chapters_db", "book.progress_db",
    "book.note_db", "book.stats_db", "book.review_cache", "ai.summary_db",
    "features.xray.db", "features.xray.events",
}) do
    package.loaded[name] = nil
end

local DB = require("utils.db")
local Event = require("utils.event")
local BookDB = require("book.books_db")
local ChapterDB = require("book.chapters_db")
local ProgressDB = require("book.progress_db")
local NoteDB = require("book.note_db")
local StatsDB = require("book.stats_db")
local SummaryDB = require("ai.summary_db")
local XrayDB = require("features.xray.db")
require("book.review_cache")
Assert.not_nil(DB.open())
Event.init({ require("features.xray.events") })

local SOURCE = "acct"
Assert.is_true(BookDB.upsert({ source_id = SOURCE, stable_id = "live", title = "在架" }))
Assert.is_true(BookDB.upsert({ source_id = SOURCE, stable_id = "gone", title = "墓碑" }))
Assert.is_true(BookDB.markDeleted(SOURCE, "gone"))
Assert.is_true(BookDB.upsert({ source_id = "local", stable_id = "/keep.epub", title = "别的源" }))
Assert.is_true(ChapterDB.upsert({
    path = "/cache/acct/live/1.html", source_id = SOURCE, stable_id = "live", chapter_idx = 1,
}))
Assert.is_true(ChapterDB.upsert({
    path = "/cache/local/keep/1.html", source_id = "local", stable_id = "/keep.epub", chapter_idx = 1,
}))
Assert.is_true(ProgressDB.upsert(SOURCE, "live", { fraction = 0.4 }))
Assert.is_true(ProgressDB.upsert("local", "/keep.epub", { fraction = 0.2 }))
Assert.is_true(NoteDB.upsert(SOURCE, "live", 0, "{}"))
Assert.is_true(NoteDB.upsert("local", "/keep.epub", 0, "{}"))
Assert.is_true(StatsDB.add({
    source_id = SOURCE, stable_id = "live", record_type = "page",
    page = 1, start_time = 1000, duration = 30, total_pages = 10,
}))
Assert.is_true(StatsDB.add({
    source_id = "local", stable_id = "/keep.epub", record_type = "page",
    page = 1, start_time = 1000, duration = 30, total_pages = 10,
}))
Assert.is_true(SummaryDB.put(SOURCE, "live", 1, "章", "摘要"))
Assert.is_true(SummaryDB.put("local", "/keep.epub", 1, "章", "留下"))
Assert.is_true(XrayDB.upsert(SOURCE, "live", { kind = "character", name = "甲", aliases = {} }))
Assert.is_true(XrayDB.upsert("local", "/keep.epub", { kind = "character", name = "乙", aliases = {} }))
Assert.is_true(DB.exec(
    [[INSERT INTO review_cache (source_id, stable_id, chapter_idx, kind, key, payload, expire)
      VALUES (?,?,?,?,?,?,?);]],
    SOURCE, "live", 1, "hot", "k", "{}", 9999999999))

Assert.is_true(BookDB.forgetSource(SOURCE))

Assert.is_nil(BookDB.get(SOURCE, "live"))
Assert.is_nil(BookDB.get(SOURCE, "gone"))
Assert.len(BookDB.pendingDeleteIds(SOURCE), 0, "墓碑不能留下来等下次登录去删远端")
Assert.eq(BookDB.get("local", "/keep.epub").title, "别的源")
Assert.is_nil(ChapterDB.get("/cache/acct/live/1.html"))
Assert.not_nil(ChapterDB.get("/cache/local/keep/1.html"))
Assert.is_nil(ProgressDB.get(SOURCE, "live"))
Assert.not_nil(ProgressDB.get("local", "/keep.epub"))
Assert.is_nil(NoteDB.get(SOURCE, "live", 0))
Assert.not_nil(NoteDB.get("local", "/keep.epub", 0))
Assert.len(StatsDB.distinctBooks(), 1)
Assert.eq(StatsDB.distinctBooks()[1].source_id, "local")
Assert.is_nil(SummaryDB.get(SOURCE, "live", 1))
Assert.eq(SummaryDB.get("local", "/keep.epub", 1).summary, "留下")
Assert.len(XrayDB.list(SOURCE, "live"), 0)
Assert.len(XrayDB.list("local", "/keep.epub"), 1)
Assert.is_nil(DB.rowexec(
    [[SELECT payload FROM review_cache WHERE source_id=?;]], SOURCE))

DB.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end

return true
