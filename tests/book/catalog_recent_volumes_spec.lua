--[[--
首页「当前阅读 / 最近阅读」的身份：卷行（seriesId:chapterId）只当「当前阅读」，
「最近阅读」按源声明的 volumeParent 归并成系列行（一部漫画一条，点开再选卷）。
真实 sqlite 执行。

@module tests.book.catalog_recent_volumes_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/catalog_recent_volumes_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end

package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return db_path end,
        ensureSettings = function() end,
        sanitizeSourceId = function(id) return id end,
    }
end
-- 卷身份 = 数字:数字；源用可选方法 volumeParent 声明归属。
package.preload["source.registry"] = function()
    return {
        list = function() return { { id = "kav", name = "Kavita", type = "chapter" } } end,
        listEnabled = function() return { { id = "kav", name = "Kavita" } } end,
        resolve = function(id)
            if id ~= "kav" then return nil end
            return {
                id = "kav",
                volumeParent = function(_, stable_id)
                    return stable_id:match("^(%d+):%d+$")
                end,
            }
        end,
    }
end
package.preload["utils.settings"] = function()
    return { get = function() return {} end }
end

local mods = { "utils.db", "utils.event", "book.books_db", "book.chapters_db",
    "book.progress_db", "book.catalog", "source.registry" }
for _idx, name in ipairs(mods) do package.loaded[name] = nil end

local Base = require("utils.db")
local BookDB = require("book.books_db")
local ProgressDB = require("book.progress_db")
local Catalog = require("book.catalog")
Assert.not_nil(Base.open())

local function shelf(id, title)
    Assert.is_true(BookDB.upsertRemote({ source_id = "kav", stable_id = id, title = title, deleted = 0 }))
end
local function volume(id, title)
    -- 不带 deleted：卷行是「非书架成员、仍是有效身份」。
    Assert.is_true(BookDB.upsertRemote({ source_id = "kav", stable_id = id, title = title }))
end
local function progress(id, fraction, at)
    Assert.not_nil(Base.exec([[INSERT INTO pending_progress (source_id, stable_id, fraction, updated_at)
        VALUES ('kav', ?, ?, ?);]], id, fraction, at))
end

shelf("10", "系列十")
volume("10:101", "系列十 · 卷1")
volume("10:102", "系列十 · 卷2")
shelf("20", "系列二十")
volume("20:201", "系列二十 · 卷1")
volume("30:301", "没有容器行的卷")   -- 父行不在库里：保持卷身份，不丢条目

-- 最近事件：系列十聚合（3500，另一台设备读的新卷只写在系列行上）→ 系列十卷1 读完（3000）
-- → 系列十卷2 在读（2400）→ 系列二十聚合 / 卷1（同一秒，stable_id 升序）
progress("10", 0.5, 3500)
progress("10:101", 1, 3000)     -- 读完的卷不能冒充「正在读」
progress("10:102", 0.9, 2400)   -- 本机唯一没读完的卷：当前阅读取它
progress("20:201", 0.8, 2000)
progress("20", 0.2, 2000)
progress("30:301", 0.6, 1000)

-- 原始行保留卷身份（「当前阅读」要显示正在读的那一卷）。
local raw = Catalog.recentRows("kav", 24)
local raw_ids = {}
for i, book in ipairs(raw) do raw_ids[i] = book.stable_id end
Assert.eq(table.concat(raw_ids, ","), "10,10:101,10:102,20,20:201,30:301")

-- 最近阅读：按系列归并（同系列多卷只留一条），顺序取该系列最近一次阅读。
local books = Catalog.recentBooks("kav", 24)
local ids = {}
for i, book in ipairs(books) do ids[i] = book.stable_id end
Assert.eq(table.concat(ids, ","), "10,20,30:301", "同一系列只列一条；没有容器行的卷照旧出现")
Assert.eq(books[1].percent, 50, "系列行显示聚合百分比，不是某一卷的")
Assert.eq(books[2].percent, 20)
Assert.eq(books[3].percent, 60, "没有容器行时沿用卷行百分比")

-- 当前阅读 = 最近系列里最新的一卷（分卷封面）；最近阅读列表里不重复列它所属的系列。
-- 系列行比卷行新、且没读完的只有卷2：不能退到已经读完的卷1。
local hero, cards = Catalog.recentShelf("kav", 24)
Assert.eq(hero.stable_id, "10:102", "当前阅读是没读完的那一卷")
Assert.eq(hero.percent, 90)
Assert.eq(#cards, 2)
Assert.eq(cards[1].stable_id, "20")
Assert.eq(cards[2].stable_id, "30:301")

-- 图书馆「最近阅读」只列在架书：系列行，卷行不进来。
local rows, count = Catalog.listBooks("kav", { sort = "recent_read" })
Assert.eq(count, 2, "卷行不是书架成员")
Assert.eq(rows[1].stable_id, "10", "系列行按自己的最近阅读时间排")
Assert.eq(rows[2].stable_id, "20")

-- 整部都读完了：没有「正在读的卷」，当前阅读退回系列行，不拿读完的卷冒充。
for _idx, id in ipairs({ "20", "20:201" }) do
    Assert.not_nil(Base.exec([[UPDATE pending_progress SET fraction=1, updated_at=4000
        WHERE source_id='kav' AND stable_id=?;]], id))
end
hero = Catalog.recentShelf("kav", 24)
Assert.eq(hero.stable_id, "20", "全部读完时当前阅读是系列行")
Assert.eq(hero.percent, 100)

Base.close()
for _idx, name in ipairs(mods) do package.loaded[name] = nil end
package.preload["utils.paths"] = nil
package.loaded["utils.paths"] = nil
package.loaded["source.registry"], package.loaded["utils.settings"] = nil, nil
package.preload["source.registry"], package.preload["utils.settings"] = nil, nil
