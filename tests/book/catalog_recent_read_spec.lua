--[[--
图书馆「最近阅读」排序：整个书架都列，按 max(本机进度时间, 云端最近阅读时间) 倒序，
都没有的排后面按加入时间倒序；卷行只在有进度时进来；云端时间只增不减。真实 sqlite 执行。

@module tests.book.catalog_recent_read_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/catalog_recent_read_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end

package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return db_path end,
        ensureSettings = function() end,
        sanitizeSourceId = function(id) return id end,
    }
end
local mods = { "utils.db", "utils.event", "book.books_db", "book.chapters_db", "book.progress_db", "book.catalog" }
for _idx, name in ipairs(mods) do package.loaded[name] = nil end

local Base = require("utils.db")
local BookDB = require("book.books_db")
require("book.progress_db")
local Catalog = require("book.catalog")
Assert.not_nil(Base.open())

local function shelf(id, inserted_at, read_at)
    Assert.is_true(BookDB.upsertRemote({ source_id = "wechat", stable_id = id, title = id,
        deleted = 0, inserted_at = inserted_at, read_at = read_at }, false, true))
end
shelf("cloud", 100, 1700005000)       -- 只在别的设备读过：云端时间
shelf("local", 200, nil)        -- 本机读过
shelf("both", 300, 1700001000)        -- 本机比云端新
shelf("never_old", 400, nil)
shelf("never_new", 500, nil)
shelf("ms", 50, 1700003000000)        -- 毫秒时间戳折成秒 = 1700003000
-- 卷行（非书架成员、sync_status=1）：有进度才进来
Assert.is_true(BookDB.upsertRemote({ source_id = "wechat", stable_id = "vol:1", title = "卷" }))
Assert.is_true(BookDB.upsertRemote({ source_id = "wechat", stable_id = "vol:2", title = "卷2" }))
for id, at in pairs({ ["local"] = 1700004000, both = 1700006000, ["vol:1"] = 1700002000 }) do
    Assert.not_nil(Base.exec([[INSERT INTO pending_progress (source_id, stable_id, fraction, updated_at)
        VALUES ('wechat', ?, 0.5, ?);]], id, at))
end

local rows, count = Catalog.listBooks("wechat", { sort = "recent_read" })
local ids = {}
for i, row in ipairs(rows) do ids[i] = row.stable_id end
Assert.eq(count, 7, "整个书架 + 有进度的卷行，没进度的卷行不进来")
Assert.eq(table.concat(ids, ","), "both,cloud,local,ms,vol:1,never_new,never_old")

-- 分页仍走 LIMIT/OFFSET
rows = Catalog.listBooks("wechat", { sort = "recent_read", limit = 2, offset = 1 })
Assert.eq(rows[1].stable_id, "cloud")
Assert.eq(rows[2].stable_id, "local")

-- 云端时间只增不减；快照没带时间也不清掉
shelf("cloud", 100, 10)
shelf("cloud", 100, nil)
Assert.eq(tonumber(Base.rowexec("SELECT read_at FROM books WHERE stable_id='cloud';")), 1700005000)

-- 其它排序不受影响
local _rows, all = Catalog.listBooks("wechat", { sort = "title" })
Assert.eq(all, 6, "其它排序只列在架书")

Base.close()
for _idx, name in ipairs(mods) do package.loaded[name] = nil end
package.preload["utils.paths"] = nil
package.loaded["utils.paths"] = nil
