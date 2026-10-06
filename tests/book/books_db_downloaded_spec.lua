--[[--
book.books_db 已下载口径：章节源目录非空且章文件登齐，其余源有 path；单书查询与列表列同一口径，真实 sqlite 执行。

@module tests.book.books_db_downloaded_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/book_downloaded_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return db_path end,
        ensureSettings = function() end,
        sanitizeSourceId = function(id) return id end,
    }
end
for _idx, name in ipairs({ "utils.db", "utils.event", "book.books_db", "book.chapters_db", "book.progress_db", "book.catalog" }) do package.loaded[name] = nil end

local Base = require("utils.db")
local BookDB = require("book.books_db")
local ChapterDB = require("book.chapters_db")
local Catalog = require("book.catalog")
Assert.not_nil(Base.open())

local function chapterFile(stable_id, idx)
    Assert.is_true(ChapterDB.upsert({
        path = "/cache/" .. stable_id .. "/" .. idx .. ".html",
        source_id = "wechat", stable_id = stable_id, chapter_idx = idx,
    }))
end

-- 章节源：目录未知 / 非法 JSON / 不是数组 / 空数组都不算下载。
Assert.is_false(BookDB.isDownloaded("wechat", "missing", true), "无书行")
Assert.is_true(BookDB.upsert({ source_id = "wechat", stable_id = "no-toc", title = "T", deleted = 0 }))
Assert.is_false(BookDB.isDownloaded("wechat", "no-toc", true), "toc 为 NULL")
for id, toc in pairs({ bad = "not json", obj = '{"a":1}', empty = "[]" }) do
    Assert.is_true(BookDB.setToc("wechat", id, toc))
    chapterFile(id, 1)
    Assert.is_false(BookDB.isDownloaded("wechat", id, true), id)
end

-- 章节源：章文件登齐才算，少一章不算；按源隔离。
Assert.is_true(BookDB.upsert({ source_id = "wechat", stable_id = "b", title = "B", deleted = 0 }))
Assert.is_true(BookDB.setToc("wechat", "b", '[{"idx":1},{"idx":2}]'))
chapterFile("b", 1)
Assert.is_false(BookDB.isDownloaded("wechat", "b", true), "缺章")
chapterFile("b", 2)
Assert.is_true(BookDB.isDownloaded("wechat", "b", true))
Assert.is_false(BookDB.isDownloaded("jdread", "b", true), "按源隔离")

-- 整本源：只看 path。
Assert.is_true(BookDB.upsert({ source_id = "moon", stable_id = "m1", title = "M1", deleted = 0 }))
Assert.is_false(BookDB.isDownloaded("moon", "m1", false))
Assert.is_true(BookDB.touchPath("moon", "m1", "/cache/m1.epub"))
Assert.is_true(BookDB.isDownloaded("moon", "m1", false))

-- 列表列与单书同口径；SELECT 与 WHERE 的绑定参数顺序不能错位（带搜索与已下载筛选）。
local rows = Catalog.listBooks({ "wechat", "moon" }, { chapter_sources = { "wechat" }, limit = 50 })
local got = {}
for _idx, row in ipairs(rows) do got[row.source_id .. "/" .. row.stable_id] = row.downloaded end
Assert.is_true(got["wechat/b"])
Assert.is_false(got["wechat/no-toc"])
Assert.is_true(got["moon/m1"])
rows = Catalog.listBooks({ "wechat", "moon" }, {
    chapter_sources = { "wechat" }, downloaded = true, search = "B", limit = 50,
})
Assert.len(rows, 1)
Assert.eq(rows[1].stable_id, "b")
Assert.is_true(rows[1].downloaded)

Base.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end

return true
