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
    "book.note_db", "book.stats_db", "book.review_cache", "ai.summary_db", "book.toc_db",
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
require("book.toc_db")
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

-- forgetPrefix：只撕 webdav://，纯本地路径留下
Assert.is_true(BookDB.upsert({
    source_id = "local", stable_id = "webdav://cloud.epub", title = "云端",
}))
Assert.is_true(ProgressDB.upsert("local", "webdav://cloud.epub", { fraction = 0.5 }))
local ok_prefix, dropped = BookDB.forgetPrefix("local", "webdav://")
Assert.is_true(ok_prefix)
Assert.eq(table.concat(dropped, ","), "webdav://cloud.epub")
Assert.is_nil(BookDB.get("local", "webdav://cloud.epub"))
Assert.is_nil(ProgressDB.get("local", "webdav://cloud.epub"))
Assert.eq(BookDB.get("local", "/keep.epub").title, "别的源", "纯本地书不动")

-- stashOldRoot：旧根在架书收下架但保留进度/统计，等 md5 重匹配；无 path 的墓碑整本撕掉
Assert.is_true(BookDB.upsert({
    source_id = "local", stable_id = "/mnt/us/documents/a.epub", title = "旧根",
    path = "/mnt/us/documents/a.epub", md5 = "digest-a",
}))
Assert.is_true(BookDB.upsert({
    source_id = "local", stable_id = "/mnt/us/documents/Books/b.epub", title = "新根内",
    path = "/mnt/us/documents/Books/b.epub",
}))
Assert.is_true(BookDB.upsert({
    source_id = "local", stable_id = "/mnt/us/other/c.epub", title = "库外",
    path = "/mnt/us/other/c.epub",
}))
Assert.is_true(BookDB.upsert({
    source_id = "local", stable_id = "webdav://keep.epub", title = "云端留",
}))
Assert.is_true(ProgressDB.upsert("local", "/mnt/us/documents/a.epub", { fraction = 0.3 }))
Assert.is_true(NoteDB.upsert("local", "/mnt/us/documents/a.epub", 0, "{}"))
Assert.is_true(StatsDB.add({
    source_id = "local", stable_id = "/mnt/us/documents/a.epub", record_type = "page",
    page = 1, start_time = 2000, duration = 10, total_pages = 5,
}))
-- 墓碑无法再匹配：整本撕掉
Assert.is_true(BookDB.upsert({
    source_id = "local", stable_id = "/mnt/us/documents/gone.epub", title = "墓碑",
}))
Assert.is_true(BookDB.markDeleted("local", "/mnt/us/documents/gone.epub"))
Assert.is_true(ProgressDB.upsert("local", "/mnt/us/documents/gone.epub", { fraction = 0.9 }))

local ok_root, root_dropped = BookDB.stashOldRoot(
    "local", "/mnt/us/documents", "/mnt/us/documents/Books")
Assert.is_true(ok_root)
Assert.eq(table.concat(root_dropped, ","), "/mnt/us/documents/gone.epub")
local stashed = BookDB.get("local", "/mnt/us/documents/a.epub")
Assert.eq(stashed.deleted, 1, "旧根书下架待重匹配")
Assert.eq(stashed.path, "/mnt/us/documents/a.epub", "保留旧路径以便稍后按文件是否还在决定去留")
Assert.eq(stashed.md5, "digest-a")
Assert.eq(ProgressDB.get("local", "/mnt/us/documents/a.epub").fraction, 0.3)
Assert.not_nil(NoteDB.get("local", "/mnt/us/documents/a.epub", 0))
Assert.is_nil(BookDB.get("local", "/mnt/us/documents/gone.epub"))
Assert.is_nil(ProgressDB.get("local", "/mnt/us/documents/gone.epub"))
Assert.eq(BookDB.get("local", "/mnt/us/documents/Books/b.epub").title, "新根内")
Assert.eq(BookDB.get("local", "/mnt/us/documents/Books/b.epub").deleted, 0)
Assert.eq(BookDB.get("local", "/mnt/us/other/c.epub").title, "库外")
Assert.eq(BookDB.get("local", "webdav://keep.epub").title, "云端留")
Assert.eq(BookDB.get("local", "/keep.epub").title, "别的源")
local stats_left = StatsDB.distinctBooks()
local stats_ids = {}
for _idx, row in ipairs(stats_left) do stats_ids[#stats_ids + 1] = row.stable_id end
table.sort(stats_ids)
Assert.is_true(table.concat(stats_ids, ","):find("/mnt/us/documents/a.epub", 1, true) ~= nil,
    "旧根统计仍在，等重匹配")

-- 待重匹配行可按 md5 被收编，迁走进度 / 笔记 / 统计后重新上架
Assert.eq(BookDB.moveCandidatesByMd5("local", "digest-a")[1], "/mnt/us/documents/a.epub")
Assert.is_true(BookDB.renameStableId(
    "local", "/mnt/us/documents/a.epub", "/mnt/us/documents/Books/novel/a.epub", "novel"))
local moved = BookDB.get("local", "/mnt/us/documents/Books/novel/a.epub")
Assert.eq(moved.deleted, 0)
Assert.eq(moved.path, "/mnt/us/documents/Books/novel/a.epub")
Assert.eq(moved.md5, "digest-a")
Assert.eq(moved.title, "旧根")
Assert.eq(ProgressDB.get("local", "/mnt/us/documents/Books/novel/a.epub").fraction, 0.3)
Assert.not_nil(NoteDB.get("local", "/mnt/us/documents/Books/novel/a.epub", 0))
Assert.is_nil(BookDB.get("local", "/mnt/us/documents/a.epub"))
local stats_after = {}
for _idx, row in ipairs(StatsDB.distinctBooks()) do stats_after[#stats_after + 1] = row.stable_id end
table.sort(stats_after)
Assert.is_true(table.concat(stats_after, ","):find("/mnt/us/documents/Books/novel/a.epub", 1, true) ~= nil)

-- 文件已不在的待重匹配行：forgetMany 整本撕掉；文件还在的留下
Assert.is_true(BookDB.upsert({
    source_id = "local", stable_id = "/mnt/us/documents/missing.epub", title = "已删",
    path = "/mnt/us/documents/missing.epub", md5 = "gone-md5",
}))
Assert.is_true(ProgressDB.upsert("local", "/mnt/us/documents/missing.epub", { fraction = 0.1 }))
Assert.is_true(BookDB.stashOldRoot("local", "/mnt/us/documents", "/mnt/us/documents/Books"))
Assert.eq(BookDB.get("local", "/mnt/us/documents/missing.epub").deleted, 1)
local ok_forget, dropped = BookDB.forgetMany("local", { "/mnt/us/documents/missing.epub" })
Assert.is_true(ok_forget)
Assert.eq(dropped[1], "/mnt/us/documents/missing.epub")
Assert.is_nil(BookDB.get("local", "/mnt/us/documents/missing.epub"))
Assert.is_nil(ProgressDB.get("local", "/mnt/us/documents/missing.epub"))
Assert.not_nil(BookDB.get("local", "/mnt/us/documents/Books/novel/a.epub"))

-- 同内容两份副本仍是两本书；待重匹配候选不会把还在盘上的那本误收编掉
Assert.is_true(BookDB.upsert({
    source_id = "local", stable_id = "/mnt/us/documents/Books/copy.epub", title = "副本",
    path = "/mnt/us/documents/Books/copy.epub", md5 = "digest-a",
}))
local candidates = BookDB.moveCandidatesByMd5("local", "digest-a")
table.sort(candidates)
Assert.eq(table.concat(candidates, ","),
    "/mnt/us/documents/Books/copy.epub,/mnt/us/documents/Books/novel/a.epub")

Assert.is_true(BookDB.stashOldRoot("local", "/mnt/us/documents", "/mnt/us/documents"), "同根空操作")
Assert.is_true(BookDB.stashOldRoot("local", "", "/mnt/us/books"), "无旧根空操作")

-- stashSyncedOutsideRoot：只收下架已同步、且不在新根下的纯本地书；库外脏行 / WebDAV 不动
Assert.is_true(BookDB.upsert({
    source_id = "local", stable_id = "/mnt/us/documents/outside.epub", title = "待收",
    path = "/mnt/us/documents/outside.epub",
}))
Assert.is_true(DB.exec("UPDATE books SET sync_status=1 WHERE stable_id=?;", "/mnt/us/documents/outside.epub"))
Assert.is_true(BookDB.stashSyncedOutsideRoot("local", "/mnt/us/documents/Books"))
Assert.eq(BookDB.get("local", "/mnt/us/documents/outside.epub").deleted, 1)
Assert.eq(BookDB.get("local", "/mnt/us/documents/outside.epub").path, "/mnt/us/documents/outside.epub")
Assert.eq(BookDB.get("local", "/mnt/us/other/c.epub").deleted, 0, "库外脏行不动")
Assert.eq(BookDB.relocatingIds("local")[1], "/mnt/us/documents/outside.epub")

-- 主动清理：书库与阅读数据分开选择，不产生远端删除墓碑。
local cancelled = {}
package.loaded["workers.tasks"] = { cancelPrefixed = function(key) cancelled[#cancelled + 1] = key end }
local function seed(source_id, stable_id)
    Assert.is_true(BookDB.upsert({
        source_id = source_id, stable_id = stable_id, title = "保留标题", read_at = 123,
    }))
    Assert.is_true(ProgressDB.upsert(source_id, stable_id, { fraction = 0.6 }))
    Assert.is_true(NoteDB.upsert(source_id, stable_id, 0, "{}"))
    Assert.is_true(StatsDB.add({
        source_id = source_id, stable_id = stable_id, record_type = "page",
        page = 1, start_time = 3000, duration = 20, total_pages = 10,
    }))
    Assert.is_true(SummaryDB.put(source_id, stable_id, 1, "章", "摘要"))
    Assert.is_true(XrayDB.upsert(source_id, stable_id, { kind = "character", name = "人物", aliases = {} }))
    Assert.is_true(ChapterDB.upsert({
        path = "/cleanup/" .. source_id .. "/" .. stable_id .. ".html",
        source_id = source_id, stable_id = stable_id, chapter_idx = 1,
    }))
end
seed("clear-books", "one")
Assert.is_true(BookDB.clearSourceData("clear-books", { books = true }))
Assert.is_nil(BookDB.get("clear-books", "one"))
Assert.is_nil(ChapterDB.get("/cleanup/clear-books/one.html"))
Assert.not_nil(ProgressDB.get("clear-books", "one"))
Assert.not_nil(NoteDB.get("clear-books", "one", 0))
Assert.not_nil(SummaryDB.get("clear-books", "one", 1))
Assert.len(XrayDB.list("clear-books", "one"), 1)
Assert.eq(tonumber(DB.rowexec("SELECT count(*) FROM reading_stats WHERE source_id=?;", "clear-books")), 1)
Assert.len(BookDB.pendingDeleteIds("clear-books"), 0)

seed("clear-reading", "one")
Assert.is_true(DB.exec("UPDATE books SET read_state=1, read_at=123 WHERE source_id=?;", "clear-reading"))
Assert.is_true(BookDB.clearSourceData("clear-reading", { reading = true }))
Assert.eq(BookDB.get("clear-reading", "one").title, "保留标题")
Assert.eq(tonumber(DB.rowexec("SELECT read_at FROM books WHERE source_id=?;", "clear-reading")), 0)
Assert.eq(BookDB.get("clear-reading", "one").read_state, 0)
Assert.not_nil(ChapterDB.get("/cleanup/clear-reading/one.html"))
Assert.is_nil(ProgressDB.get("clear-reading", "one"))
Assert.is_nil(NoteDB.get("clear-reading", "one", 0))
Assert.is_nil(SummaryDB.get("clear-reading", "one", 1))
Assert.len(XrayDB.list("clear-reading", "one"), 0)
Assert.eq(tonumber(DB.rowexec("SELECT count(*) FROM reading_stats WHERE source_id=?;", "clear-reading")), 0)
Assert.eq(cancelled[1], "xray\0clear-reading")

-- WebDAV / 本地分开；孤立阅读行也清掉，另一源同名身份不受影响。
seed("local", "/cleanup-local.epub")
seed("local", "webdav://cleanup.epub")
seed("another", "webdav://cleanup.epub")
Assert.is_true(NoteDB.upsert("local", "webdav://orphan.epub", 0, "{}"))
Assert.is_true(ProgressDB.upsert("local", "webdav://orphan.epub", { fraction = 0.2 }))
Assert.is_true(BookDB.clearSourceData("local", {
    books = true, reading = true, stable_prefix = "webdav://",
}))
Assert.is_nil(BookDB.get("local", "webdav://cleanup.epub"))
Assert.is_nil(NoteDB.get("local", "webdav://orphan.epub", 0))
Assert.is_nil(ProgressDB.get("local", "webdav://orphan.epub"))
Assert.not_nil(NoteDB.get("local", "/cleanup-local.epub", 0))
Assert.not_nil(ProgressDB.get("another", "webdav://cleanup.epub"))
Assert.len(XrayDB.list("another", "webdav://cleanup.epub"), 1)
Assert.is_true(NoteDB.upsert("local", "webdav://keep.epub", 0, "{}"))
Assert.is_true(BookDB.clearSourceData("local", {
    reading = true, stable_prefix = "webdav://", exclude = true,
}))
Assert.not_nil(BookDB.get("local", "/cleanup-local.epub"))
Assert.is_nil(NoteDB.get("local", "/cleanup-local.epub", 0))
Assert.not_nil(NoteDB.get("local", "webdav://keep.epub", 0))

-- 某张表拒绝删除时整个库事务回滚，不出现书库清了、笔记清到一半的状态。
seed("rollback", "one")
local original_exec = DB.exec
DB.exec = function(sql, ...)
    if sql:find("^DELETE FROM notes") then return nil end
    return original_exec(sql, ...)
end
Assert.is_false(BookDB.clearSourceData("rollback", { books = true, reading = true }))
DB.exec = original_exec
Assert.not_nil(BookDB.get("rollback", "one"))
Assert.not_nil(ProgressDB.get("rollback", "one"))
Assert.not_nil(NoteDB.get("rollback", "one", 0))
Assert.not_nil(ChapterDB.get("/cleanup/rollback/one.html"))
Assert.errors(function() BookDB.clearSourceData("rollback", {}) end, "no data selected")

-- Store 收集当前路径、孤立阅读身份及衍生版 / 缺原文件的边车；不删原始文件。
local original = Config.dir() .. "/cleanup-original.epub"
local file = assert(io.open(original, "wb"))
file:write("original")
file:close()
Assert.is_true(BookDB.upsert({ source_id = "paths", stable_id = "book", path = original }))
Assert.is_true(NoteDB.upsert("paths", "orphan", 0, "{}"))
local root = Config.dir() .. "/cleanup-cache"
package.loaded["utils.paths"].bookWorkDir = function(id, source_id) return root .. "/" .. source_id .. "/" .. id end
local dirs = {
    [root .. "/paths/book"] = { "book.epub", "reflow", "missing.sdr" },
    [root .. "/paths/book/reflow"] = { "book.epub" },
    [root .. "/paths/book/missing.sdr"] = { "metadata.epub.lua.old" },
    [root .. "/paths/orphan"] = { "gone.sdr" },
    [root .. "/paths/orphan/gone.sdr"] = { "metadata.epub.lua" },
}
package.loaded["libs/libkoreader-lfs"] = {
    symlinkattributes = function(path) return dirs[path] and "directory" or "file" end,
    dir = function(path)
        local index = 0
        return function() index = index + 1; return dirs[path][index] end
    end,
}
local seen, sidecar_ok = {}, false
package.loaded["book.sidecar"] = { clearReading = function(path)
    seen[path] = true
    return sidecar_ok
end }
local Store = require("book.store")
Assert.is_false(Store.clearSourceData("paths", { reading = true }))
Assert.not_nil(NoteDB.get("paths", "orphan", 0), "边车写失败不继续删库")
sidecar_ok = true
Assert.is_true(Store.clearSourceData("paths", { reading = true }))
Assert.is_true(seen[original])
Assert.is_true(seen[root .. "/paths/book/reflow/book.epub"])
Assert.is_true(seen[root .. "/paths/book/missing.epub"])
Assert.is_true(seen[root .. "/paths/orphan/gone.epub"])
Assert.is_nil(NoteDB.get("paths", "orphan", 0))
Assert.not_nil(BookDB.get("paths", "book"))
file = assert(io.open(original, "rb"))
Assert.eq(file:read("*a"), "original")
file:close()
os.remove(original)

DB.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end

return true
