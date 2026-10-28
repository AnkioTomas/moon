--[[--
图书馆「最近阅读」排序：只列在架书（卷行是进度身份、不是书架成员，最近阅读时间写在系列行上），
按 max(进度时间, 云端最近阅读时间) 倒序，都没有的排后面按加入时间倒序；云端时间只增不减。真实 sqlite 执行。

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
-- 书架缓存能力查询会解析源实例；这里的源都不声明 shelf_cache。
package.loaded["source.registry"] = nil
package.preload["source.registry"] = function()
    return {
        list = function() return { { id = "wechat", name = "微信读书", type = "chapter" } } end,
        listEnabled = function() return { { id = "wechat", name = "微信读书" } } end,
        resolve = function() return nil end,
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
-- 卷行（非书架成员、sync_status=1）：不是书架成员，最近阅读也不列它
Assert.is_true(BookDB.upsertRemote({ source_id = "wechat", stable_id = "vol:1", title = "卷" }))
Assert.is_true(BookDB.upsertRemote({ source_id = "wechat", stable_id = "vol:2", title = "卷2" }))
for id, at in pairs({ ["local"] = 1700004000, both = 1700006000, ["vol:1"] = 1700002000 }) do
    Assert.not_nil(Base.exec([[INSERT INTO pending_progress (source_id, stable_id, fraction, updated_at)
        VALUES ('wechat', ?, 0.5, ?);]], id, at))
end

local rows, count = Catalog.listBooks("wechat", { sort = "recent_read" })
local ids = {}
for i, row in ipairs(rows) do ids[i] = row.stable_id end
Assert.eq(count, 6, "只列在架书，卷行不进来")
Assert.eq(table.concat(ids, ","), "both,cloud,local,ms,never_new,never_old")

-- 分页仍走 LIMIT/OFFSET
rows = Catalog.listBooks("wechat", { sort = "recent_read", limit = 2, offset = 1 })
Assert.eq(rows[1].stable_id, "cloud")
Assert.eq(rows[2].stable_id, "local")

-- 云端时间只增不减；快照没带时间也不清掉
shelf("cloud", 100, 10)
shelf("cloud", 100, nil)
Assert.eq(tonumber(Base.rowexec("SELECT read_at FROM books WHERE stable_id='cloud';")), 1700005000)

-- 下架后换身份重新上架的书：旧行（非成员、有进度）与在架行同名，只列在架那本
Assert.is_true(BookDB.upsertRemote({ source_id = "wechat", stable_id = "old_id", title = "never_old" }))
Assert.not_nil(Base.exec([[INSERT INTO pending_progress (source_id, stable_id, fraction, updated_at)
    VALUES ('wechat', 'old_id', 0.3, 1700007000);]]))
rows, count = Catalog.listBooks("wechat", { sort = "recent_read" })
Assert.eq(count, 6, "下架行不进最近阅读，同名的在架行照常列出")
for _idx, row in ipairs(rows) do Assert.is_true(row.stable_id ~= "old_id") end

-- 本地书文件没了（下架并清空 path）：有进度也不留在最近阅读里
Assert.is_true(BookDB.upsertRemote({ source_id = "local", stable_id = "/gone.epub", title = "gone" }))
Assert.not_nil(Base.exec([[INSERT INTO pending_progress (source_id, stable_id, fraction, updated_at)
    VALUES ('local', '/gone.epub', 0.3, 1700008000);]]))
_rows, all = Catalog.listBooks("local", { sort = "recent_read" })
Assert.eq(all, 0, "文件已删的本地书不进最近阅读")

-- 其它排序不受影响
local _rows, all = Catalog.listBooks("wechat", { sort = "title" })
Assert.eq(all, 6, "其它排序只列在架书")

Base.close()
for _idx, name in ipairs(mods) do package.loaded[name] = nil end
package.preload["utils.paths"], package.preload["source.registry"] = nil, nil
package.loaded["utils.paths"], package.loaded["source.registry"] = nil, nil
