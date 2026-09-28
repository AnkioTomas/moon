--[[--
db.book.tocLength：目录条数在 SQL 里算（json_array_length），真实 sqlite 执行。

@module tests.db.book_toc_length_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/book_toc_length_spec.sqlite3"
for _, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return db_path end,
        ensureSettings = function() end,
        sanitizeSourceId = function(id) return id end,
    }
end
for _, name in ipairs({ "db.base", "db.book" }) do package.loaded[name] = nil end

local Base = require("db.base")
local BookDB = require("db.book")
Assert.not_nil(Base.open())

Assert.eq(BookDB.tocLength("wechat", "missing"), 0, "无书行")
Assert.is_true(BookDB.upsert({ source_id = "wechat", stable_id = "no-toc", title = "T" }))
Assert.eq(BookDB.tocLength("wechat", "no-toc"), 0, "toc 为 NULL")

Assert.is_true(BookDB.setToc("wechat", "b", '[{"idx":1},{"idx":2},{"idx":3}]'))
Assert.eq(BookDB.tocLength("wechat", "b"), 3)
Assert.eq(BookDB.tocLength("jdread", "b"), 0, "按源隔离")

Assert.is_true(BookDB.setToc("wechat", "bad", "not json"))
Assert.eq(BookDB.tocLength("wechat", "bad"), 0, "非法 JSON")
Assert.is_true(BookDB.setToc("wechat", "obj", '{"a":1}'))
Assert.eq(BookDB.tocLength("wechat", "obj"), 0, "不是数组")
Assert.is_true(BookDB.setToc("wechat", "empty", "[]"))
Assert.eq(BookDB.tocLength("wechat", "empty"), 0)

Base.close()
for _, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
