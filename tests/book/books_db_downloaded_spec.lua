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

-- 下载校验范围：纯本地书（path 即 stable_id）归扫盘，不校验；WebDAV 书的 path 是下载副本，要校验。
Assert.is_true(BookDB.touchPath("local", "/lib/a.epub", "/lib/a.epub"))
Assert.is_true(BookDB.touchPath("local", "webdav://b.epub", "/old/b.epub"))
local checked = {}
for _idx, row in ipairs(BookDB.pathsBySource("local")) do checked[row.stable_id] = row.path end
Assert.is_nil(checked["/lib/a.epub"], "纯本地书不校验")
Assert.eq(checked["webdav://b.epub"], "/old/b.epub", "WebDAV 下载副本要校验")
Assert.is_true(BookDB.clearPaths({ { source_id = "local", stable_id = "webdav://b.epub", path = "/old/b.epub" } }))
Assert.is_false(BookDB.isDownloaded("local", "webdav://b.epub", false), "副本没了撤掉已下载标记")

-- 离线书架（05 A4）：已缓存 series ∪ 已下载 ∪ 卷行；count 与分页共用同一 where。
do
    local shelf_ids = { ["700"] = true }
    package.loaded["source.registry"] = {
        resolve = function(id)
            if id ~= "ext.kavita" then return nil end
            return {
                id = "ext.kavita",
                capabilities = function() return { shelf_cache = true } end,
                shelfCache = function()
                    local mark = {}
                    for stable_id in pairs(shelf_ids) do mark[stable_id] = true end
                    return { series_ids = mark, mark = mark, cover = {} }
                end,
            }
        end,
    }
    Assert.is_true(BookDB.upsert({ source_id = "ext.kavita", stable_id = "700", title = "已缓存系列", deleted = 0 }))
    Assert.is_true(BookDB.upsert({ source_id = "ext.kavita", stable_id = "701", title = "没缓存没下载", deleted = 0 }))
    Assert.is_true(BookDB.upsert({ source_id = "ext.kavita", stable_id = "702", title = "历史 cbz",
        path = "/cache/702.cbz", deleted = 0 }))
    -- 卷行：非书架成员身份行（deleted=1 + sync_status=1），只有进度时才出现在最近阅读。
    Assert.is_true(BookDB.upsertRemote({ source_id = "ext.kavita", stable_id = "700:7001", title = "第七百卷" }))
    Assert.is_true(ProgressDB.upsert("ext.kavita", "700:7001", { fraction = 0.5, updated_at = os.time() }))
    Assert.is_true(BookDB.upsert({ source_id = "local", stable_id = "/lib/x.epub", title = "本地书",
        path = "/lib/x.epub", deleted = 0 }))

    local offline_rows, offline_count = Catalog.listBooks("ext.kavita", {
        sort = "recent_read", offline_only = true, chapter_sources = {}, limit = 50,
    })
    local got_offline = {}
    for _idx, row in ipairs(offline_rows) do got_offline[row.stable_id] = row end
    Assert.is_true(got_offline["700"] ~= nil, "已缓存 series 可见")
    Assert.is_true(got_offline["700"].cache_mark, "离线行也带 cache_mark")
    Assert.is_nil(got_offline["701"], "没缓存没下载：离线隐藏")
    Assert.is_true(got_offline["702"] ~= nil, "已下载的历史 cbz 仍可离线读")
    Assert.is_true(got_offline["700:7001"] ~= nil, "卷行放行（不误杀上次读到一半的书）")
    Assert.eq(offline_count, 3, "count 与 where 一致")

    -- 分页与总数：翻页只改取出范围，不改 count。
    local page1, count1 = Catalog.listBooks("ext.kavita", {
        sort = "recent_read", offline_only = true, chapter_sources = {}, limit = 2, offset = 0,
    })
    local page2, count2 = Catalog.listBooks("ext.kavita", {
        sort = "recent_read", offline_only = true, chapter_sources = {}, limit = 2, offset = 2,
    })
    Assert.len(page1, 2)
    Assert.len(page2, 1)
    Assert.eq(count1, 3)
    Assert.eq(count2, count1, "分页总数不受页码影响")

    -- 在线（不传 offline_only）：没缓存的照旧列出，只是没有标记。
    local online_rows, online_count = Catalog.listBooks("ext.kavita", { limit = 50 })
    Assert.eq(online_count, 3, "在线列出全部在架书")
    local got_online = {}
    for _idx, row in ipairs(online_rows) do got_online[row.stable_id] = row end
    Assert.is_true(got_online["701"] ~= nil)
    Assert.is_nil(got_online["701"].cache_mark)
    Assert.is_nil(got_online["700:7001"], "默认排序不列卷行")

    -- 混合源：没声明 shelf_cache 的源原样放行。
    local mixed_rows, mixed_count = Catalog.listBooks({ "ext.kavita", "local" }, {
        sort = "recent_read", offline_only = true, chapter_sources = {}, limit = 50,
    })
    local got_mixed = {}
    for _idx, row in ipairs(mixed_rows) do got_mixed[row.source_id .. "/" .. row.stable_id] = true end
    Assert.is_true(got_mixed["local//lib/x.epub"], "别的源不受离线过滤")
    Assert.is_nil(got_mixed["ext.kavita/701"])
    Assert.eq(mixed_count, 4, "本地的行加上可离线的 Kavita 行")

    package.loaded["source.registry"] = nil
end

Base.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end

return true
