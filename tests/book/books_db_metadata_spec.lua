--[[--
远端元数据只补充有效字段，空快照不能清本地资料；主动编辑仍可清空。真实 SQLite 执行。

@module tests.book.books_db_metadata_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")
if not pcall(require, "lua-ljsqlite3/init") then Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块") end

local path = Config.dir() .. "/book_metadata_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(path .. suffix) end
package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return { dbPath = function() return path end, ensureSettings = function() end,
        sanitizeSourceId = function(id) return id end }
end
local DB = require("utils.db")
local BookDB = require("book.books_db")
Assert.not_nil(DB.open())

local full = {
    source_id = "fanqie", stable_id = "metadata", deleted = 0,
    title = "书名", authors = "作者", intro = "书籍简介",
    category = "悬疑", series = "系列", cover = "https://example.com/cover.jpg",
}
Assert.is_true(BookDB.upsertRemote({ source_id = full.source_id, stable_id = full.stable_id, deleted = 0 }))
Assert.is_nil(BookDB.get(full.source_id, full.stable_id).intro)
Assert.is_true(BookDB.upsertRemote(full))
Assert.eq(BookDB.get(full.source_id, full.stable_id).intro, full.intro)
Assert.is_true(BookDB.upsertRemote({ source_id = full.source_id, stable_id = full.stable_id, deleted = 0 }))
Assert.eq(BookDB.get(full.source_id, full.stable_id).authors, full.authors, "缺省字段也不能清已有资料")

local empty = { source_id = full.source_id, stable_id = full.stable_id, deleted = 0,
    title = "", authors = "", intro = "", category = "", series = "", cover = "" }
for _idx, force in ipairs({ false, true }) do
    Assert.is_true(BookDB.reconcile(full.source_id, { empty }, { force = force }))
    local row = BookDB.get(full.source_id, full.stable_id)
    for _field_idx, key in ipairs({ "title", "authors", "intro", "category", "series", "cover" }) do
        Assert.eq(row[key], full[key], "空快照不能清空 " .. key)
    end
end

Assert.is_true(BookDB.markDeleted(full.source_id, full.stable_id))
Assert.is_true(BookDB.upsertLocal(full))
Assert.is_true(BookDB.markSynced(full.source_id, full.stable_id))
Assert.is_true(BookDB.reconcile(full.source_id, { empty }))
Assert.eq(BookDB.get(full.source_id, full.stable_id).intro, full.intro, "重新加入后再同步不能丢资料")

Assert.is_true(BookDB.upsertLocal({ source_id = full.source_id, stable_id = full.stable_id,
    title = full.title, authors = "", intro = "", category = "", series = "" }))
local cleared = BookDB.get(full.source_id, full.stable_id)
Assert.eq(cleared.authors, "", "手动编辑仍能清空作者")
Assert.eq(cleared.intro, "")
Assert.is_true(BookDB.upsertLocal(full))
Assert.is_true(BookDB.markDeleted(full.source_id, full.stable_id))
Assert.is_true(BookDB.upsertLocal(full))
Assert.is_true(BookDB.upsertRemote({ source_id = full.source_id, stable_id = full.stable_id,
    authors = "远端作者", intro = "远端简介", deleted = 0 }))
Assert.eq(BookDB.get(full.source_id, full.stable_id).authors, full.authors, "非空本地脏资料仍优先")

DB.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(path .. suffix) end
