--[[--
新增书源的详情落库与漫画章节身份登记；只用沙箱数据库。

@module tests.source.detail_persistence_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field, assign-type-mismatch

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")
local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块") end
package.loaded.json = require("support.json_stub")

local db_path = Config.dir() .. "/source_detail_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
local Paths = require("utils.paths")
package.loaded["utils.paths"] = setmetatable({
    dbPath = function() return db_path end,
}, { __index = Paths })
local DB = require("utils.db")
local BookDB = require("book.books_db")
local ChapterDB = require("book.chapters_db")
local SourceBase = require("source.base")

for _idx, id in ipairs({ "dedao", "douban", "ireader", "kuaikan", "netease", "shuqi", "tadu", "zhihu", "zymk" }) do
    local detail
    local function respond(_stable_id, cb)
        if id == "douban" or id == "shuqi" then return SourceBase.defer(cb, detail) end
        return SourceBase.defer(cb, { book = detail, info = {}, chapters = { { idx = 1, uid = "1" } } })
    end
    package.loaded["source." .. id .. ".client"] = {
        detailAsync = respond, infoAsync = respond, topicAsync = respond,
        catalogAsync = respond, simpleAsync = respond,
        hasAccount = function() return false end,
    }
    local Mapper = require("source." .. id .. ".mapper")
    Mapper.detail = function() return detail end
    Mapper.chapters = function() return { { idx = 1, uid = "1" } } end
    local source = require("source." .. id).new()

    for _case, state in ipairs({
        { stable_id = "preview" },
        { stable_id = "member", deleted = 0 },
        { stable_id = "tombstone", deleted = 1, dirty = true },
    }) do
        if state.deleted ~= nil then
            Assert.is_true(BookDB.upsertRemote({
                source_id = id, stable_id = state.stable_id, deleted = state.deleted,
                title = "本地书名", authors = "本地作者", intro = "本地简介",
            }))
            if state.dirty then
                Assert.is_true(DB.exec("UPDATE books SET sync_status=0 WHERE source_id=? AND stable_id=?;",
                    id, state.stable_id) ~= nil)
            end
        end
        detail = {
            source_id = id, stable_id = state.stable_id, title = "远端书名",
            authors = "远端作者", intro = "远端简介",
        }
        local received, err
        source:getDetailAsync({ source_id = id, stable_id = state.stable_id },
            function(row, reason) received, err = row, reason end)
        Stubs.flush()
        Assert.is_nil(err)
        Assert.is_true(received ~= nil)
        local stored = BookDB.get(id, state.stable_id)
        Assert.eq(stored.intro, state.dirty and "本地简介" or "远端简介")
        Assert.eq(stored.authors, state.dirty and "本地作者" or "远端作者")
        Assert.eq(stored.deleted, state.deleted or 1)
        Assert.eq(stored.sync_status, state.dirty and 0 or 1)
        Assert.is_true(stored.meta.detail_at > 0)
    end

    local upsert = BookDB.upsertRemote
    BookDB.upsertRemote = function() return false end
    local failed, save_err
    source:getDetailAsync({ source_id = id, stable_id = detail.stable_id },
        function(row, err) failed, save_err = row, err end)
    Stubs.flush()
    BookDB.upsertRemote = upsert
    Assert.is_nil(failed)
    Assert.eq(save_err, "书籍信息保存失败")
end

for _idx, id in ipairs({ "kuaikan", "zymk" }) do
    local Chapter = require("source." .. id .. ".chapter")
    local identity = { source_id = id, stable_id = "cache" }
    Assert.is_true(BookDB.upsertRemote({
        source_id = id, stable_id = "cache", title = "漫画", path = "/reading.cbz",
    }))
    Chapter.materializeAsync = function(_identity, chapter, _progress, cb)
        return SourceBase.defer(cb, "/" .. id .. "-" .. chapter.uid .. ".cbz")
    end
    local toc = { { uid = "1" }, { uid = "2" }, { uid = "3" } }
    local result
    Chapter.prefetchAsync(identity, toc, 1, 2, nil, function(cached, total, failed, err)
        result = { cached, total, failed, err }
    end)
    Stubs.flush()
    Assert.eq(result[1], 2)
    Assert.eq(result[2], 2)
    Assert.eq(result[3], 0)
    Assert.is_true(ChapterDB.has(id, "cache"))
    Assert.eq(ChapterDB.get("/" .. id .. "-2.cbz").chapter_idx, 2)
    Assert.eq(ChapterDB.get("/" .. id .. "-3.cbz").chapter_idx, 3)
    Assert.eq(BookDB.get(id, "cache").path, "/reading.cbz")

    local upsert = ChapterDB.upsert
    ChapterDB.upsert = function() return false end
    Chapter.prefetchAsync(identity, toc, 0, 1, nil, function(cached, total, failed, err)
        result = { cached, total, failed, err }
    end)
    Stubs.flush()
    ChapterDB.upsert = upsert
    Assert.eq(result[1], 0)
    Assert.eq(result[2], 1)
    Assert.eq(result[3], 1)
    Assert.eq(result[4], "书籍信息保存失败")
    Assert.is_nil(ChapterDB.get("/" .. id .. "-1.cbz"))

    local called = false
    local job = Chapter.prefetchAsync(identity, toc, 0, 1, nil, function() called = true end)
    job.cancel()
    Stubs.flush()
    Assert.is_false(called)
    Assert.is_nil(ChapterDB.get("/" .. id .. "-1.cbz"))
end

DB.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
