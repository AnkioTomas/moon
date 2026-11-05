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

-- 脏行也允许补空字段：用户改过的非空值保留，空的作者 / 简介可以拿远端补上。
local fill_id = "fill_empty_meta"
Assert.is_true(BookDB.upsertLocal({ source_id = full.source_id, stable_id = fill_id, title = "空字段",
    authors = "", intro = nil }))
Assert.eq(BookDB.get(full.source_id, fill_id).sync_status, 0, "本地写入是脏行")
Assert.is_true(BookDB.fillEmptyMeta(full.source_id, fill_id, "远端作者", "远端简介"))
local filled = BookDB.get(full.source_id, fill_id)
Assert.eq(filled.authors, "远端作者", "空作者被补上")
Assert.eq(filled.intro, "远端简介", "空简介被补上")
Assert.eq(filled.sync_status, 0, "补空不动脏标记")
Assert.is_false(BookDB.fillEmptyMeta(full.source_id, fill_id, "另一个作者", "另一段简介"),
    "没有空字段就不再写")
Assert.is_true(BookDB.upsertLocal({ source_id = full.source_id, stable_id = fill_id, title = "空字段",
    authors = "本地作者", intro = "" }))
Assert.is_true(BookDB.fillEmptyMeta(full.source_id, fill_id, "远端作者", "远端简介"))
Assert.eq(BookDB.get(full.source_id, fill_id).authors, "本地作者", "非空本地作者不被覆盖")
Assert.eq(BookDB.get(full.source_id, fill_id).intro, "远端简介", "只补空的那一项")

Assert.is_true(BookDB.markSynced(full.source_id, full.stable_id))
Assert.is_true(BookDB.upsertRemote({
    source_id = full.source_id, stable_id = full.stable_id, deleted = 0,
    category_authoritative = true,
}))
local cleared_category = BookDB.get(full.source_id, full.stable_id)
Assert.is_nil(cleared_category.category, "书架快照声明未分类时清掉旧分类")
Assert.eq(cleared_category.title, full.title, "声明分类不顺手清别的字段")
Assert.is_true(BookDB.upsertRemote({
    source_id = full.source_id, stable_id = full.stable_id, deleted = 0,
    category = "悬疑", category_authoritative = true,
}))
Assert.is_true(BookDB.upsertRemote({
    source_id = full.source_id, stable_id = full.stable_id, deleted = 0,
}))
Assert.eq(BookDB.get(full.source_id, full.stable_id).category, "悬疑", "没声明分类口径的更新不清分类")
Assert.is_true(BookDB.markDeleted(full.source_id, full.stable_id))
Assert.is_true(BookDB.upsertLocal({
    source_id = full.source_id, stable_id = full.stable_id,
    title = full.title, category = "本地分组",
}))
Assert.is_true(BookDB.upsertRemote({
    source_id = full.source_id, stable_id = full.stable_id, deleted = 0,
    category_authoritative = true,
}))
Assert.eq(BookDB.get(full.source_id, full.stable_id).category, "本地分组", "脏行的分类不被快照清掉")

DB.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(path .. suffix) end
