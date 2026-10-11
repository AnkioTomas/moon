--[[--
book.books_db 加入时间：旧库 fetched_at 回填；身份行（inserted_at=0）首次上架时补写，之后不改；
只登记身份不上架的行保持 0。真实 sqlite 执行。

@module tests.book.books_db_inserted_at_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local sqlite_ok, SQL = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/book_inserted_at_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end

-- v0.0.8 的旧表：加入时间在 fetched_at，没有 inserted_at 列。
local legacy = SQL.open(db_path)
legacy:exec([[
CREATE TABLE books (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL, md5 TEXT, title TEXT,
  authors TEXT, category TEXT, series TEXT, intro TEXT, fetched_at INTEGER NOT NULL DEFAULT 0,
  path TEXT, PRIMARY KEY (source_id, stable_id)
);
INSERT INTO books (source_id, stable_id, title, fetched_at) VALUES ('moon', 'old', '旧书', 1700000000);
INSERT INTO books (source_id, stable_id, title, fetched_at) VALUES ('moon', 'never', '未取过', 0);
]])
legacy:close()

package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return db_path end,
        ensureSettings = function() end,
        sanitizeSourceId = function(id) return id end,
    }
end
for _idx, name in ipairs({ "utils.db", "utils.event", "book.books_db", "book.chapters_db" }) do
    package.loaded[name] = nil
end

local Base = require("utils.db")
local BookDB = require("book.books_db")
Assert.not_nil(Base.open())

Assert.eq(BookDB.get("moon", "old").inserted_at, 1700000000, "旧库加入时间从 fetched_at 回填")
Assert.eq(BookDB.get("moon", "never").inserted_at, 0, "fetched_at 也没有的不编")

-- 身份行：只登记路径 / 远端非成员行不算加入。
Assert.is_true(BookDB.touchPath("local", "/a.epub", "/a.epub"))
Assert.eq(BookDB.get("local", "/a.epub").inserted_at, 0)
Assert.is_true(BookDB.upsertRemote({ source_id = "moon", stable_id = "ghost", title = "G", inserted_at = 1800000000 }))
Assert.eq(BookDB.get("moon", "ghost").inserted_at, 0, "非成员远端行仍是身份行")

-- 上架补写，之后不改。
Assert.is_true(BookDB.upsert({ source_id = "local", stable_id = "/a.epub", title = "A", inserted_at = 1800000001 }))
Assert.eq(BookDB.get("local", "/a.epub").inserted_at, 1800000001, "身份行上架补写加入时间")
Assert.is_true(BookDB.upsert({ source_id = "local", stable_id = "/a.epub", title = "A2", inserted_at = 1900000000 }))
Assert.eq(BookDB.get("local", "/a.epub").inserted_at, 1800000001, "已有加入时间不被覆盖")

Assert.is_true(BookDB.upsertRemote({ source_id = "moon", stable_id = "ghost", deleted = 0, inserted_at = 1800000002 }))
Assert.eq(BookDB.get("moon", "ghost").inserted_at, 1800000002, "远端在架行上架补写")
Assert.is_true(BookDB.upsertRemote({ source_id = "moon", stable_id = "old", deleted = 0, inserted_at = 1900000000 }))
Assert.eq(BookDB.get("moon", "old").inserted_at, 1700000000, "回填的旧时间不被远端覆盖")

Assert.is_true(BookDB.setToc("wechat", "w1", "[]"))
Assert.is_true(BookDB.upsertLocal({ source_id = "wechat", stable_id = "w1", title = "W", inserted_at = 1800000003 }))
Assert.eq(BookDB.get("wechat", "w1").inserted_at, 1800000003, "upsertLocal 同样补写")

Base.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
