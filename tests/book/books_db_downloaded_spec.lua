--[[--
book.books_db 已下载口径：章节源从当前阅读章（无进度则第 1 章）起往后连续无缺口（不看目录），其余源有 path；单书查询与列表列同一口径，真实 sqlite 执行。

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
local ProgressDB = require("book.progress_db")
Assert.not_nil(Base.open())

local function chapterFile(stable_id, idx)
    Assert.is_true(ChapterDB.upsert({
        path = "/cache/" .. stable_id .. "/" .. idx .. ".html",
        source_id = "wechat", stable_id = stable_id, chapter_idx = idx,
    }))
end

-- 章节源：一章都没登记不算下载。
Assert.is_false(BookDB.isDownloaded("wechat", "missing", true), "无书行")
Assert.is_true(BookDB.upsert({ source_id = "wechat", stable_id = "none", title = "T", deleted = 0 }))
Assert.is_false(BookDB.isDownloaded("wechat", "none", true), "没有章节")

-- 章节源：无进度时从第 1 章起连续无缺口才算，不看目录长度。
Assert.is_true(BookDB.upsert({ source_id = "wechat", stable_id = "gap", title = "G", deleted = 0 }))
chapterFile("gap", 2)
Assert.is_false(BookDB.isDownloaded("wechat", "gap", true), "缺第 1 章")
chapterFile("gap", 4)
chapterFile("gap", 1)
Assert.is_false(BookDB.isDownloaded("wechat", "gap", true), "中间缺第 3 章")
chapterFile("gap", 3)
Assert.is_true(BookDB.isDownloaded("wechat", "gap", true), "补齐缺口")

Assert.is_true(BookDB.upsert({ source_id = "wechat", stable_id = "b", title = "B", deleted = 0 }))
chapterFile("b", 1)
Assert.is_true(BookDB.isDownloaded("wechat", "b", true), "只有第 1 章也连续")
chapterFile("b", 2)
Assert.is_true(BookDB.setToc("wechat", "b", '[{"idx":1},{"idx":2},{"idx":3},{"idx":4}]'))
Assert.is_true(BookDB.isDownloaded("wechat", "b", true), "连载更新目录变长，已缓存部分仍算已下载")
Assert.is_true(BookDB.setToc("wechat", "b", "not json"))
Assert.is_true(BookDB.isDownloaded("wechat", "b", true), "目录缓存坏了也不影响")
Assert.is_false(BookDB.isDownloaded("jdread", "b", true), "按源隔离")

-- 有阅读进度：从当前章起往后连续即可，之前的章不管。
Assert.is_true(BookDB.upsert({ source_id = "wechat", stable_id = "tail", title = "R", deleted = 0 }))
Assert.is_true(ProgressDB.upsert("wechat", "tail", { fraction = 0.5, chapter_idx = 5 }))
chapterFile("tail", 2)
chapterFile("tail", 6)
Assert.is_false(BookDB.isDownloaded("wechat", "tail", true), "当前章没缓存")
chapterFile("tail", 5)
Assert.is_true(BookDB.isDownloaded("wechat", "tail", true), "当前章起连续，前面缺 1/3/4 不管")
chapterFile("tail", 8)
Assert.is_false(BookDB.isDownloaded("wechat", "tail", true), "当前章之后缺第 7 章")
Assert.is_true(ProgressDB.upsert("wechat", "tail", { fraction = 0.9, chapter_idx = 8 }))
Assert.is_true(BookDB.isDownloaded("wechat", "tail", true), "读过缺口后又算已下载")
Assert.is_true(ProgressDB.upsert("wechat", "gap", { fraction = 0.1 }))
Assert.is_true(BookDB.isDownloaded("wechat", "gap", true), "进度无章号按第 1 章起算")

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
Assert.is_false(got["wechat/none"])
Assert.is_true(got["wechat/gap"])
Assert.is_true(got["wechat/tail"])
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
