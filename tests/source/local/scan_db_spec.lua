--[[--
source.local.scan_db：本地扫盘索引表 local_scan，真实 sqlite 执行。

@module tests.source.local.scan_db_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/scan_db_spec.sqlite3"
for _, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return db_path end,
        ensureSettings = function() end,
        sanitizeSourceId = function(id) return id end,
    }
end
for _, name in ipairs({ "utils.db", "source.local.scan_db" }) do package.loaded[name] = nil end

local Base = require("utils.db")
local ScanDB = require("source.local.scan_db")
Assert.not_nil(Base.open())

-- 空表
Assert.is_nil(next(ScanDB.all()))

-- 首轮写入；md5 读不出（nil）的行照样记指纹
Assert.is_true(ScanDB.save({}, {
    { path = "/b/a.epub", fp = "10:1", md5 = "m-a", cover_tried = true },
    { path = "/b/x.txt", fp = "5:1", md5 = nil },
}))
local index = ScanDB.all()
Assert.eq(index["/b/a.epub"].fp, "10:1")
Assert.eq(index["/b/a.epub"].md5, "m-a")
Assert.is_true(index["/b/a.epub"].cover)
Assert.is_nil(index["/b/x.txt"].md5)
Assert.is_false(index["/b/x.txt"].cover)

-- 收敛：改过的更新、盘上没了的删掉、新书插入
Assert.is_true(ScanDB.save(index, {
    { path = "/b/a.epub", fp = "11:2", md5 = "m-a2", cover_tried = false },
    { path = "/b/new.pdf", fp = "7:3", md5 = "m-n", cover_tried = true },
}))
index = ScanDB.all()
Assert.eq(index["/b/a.epub"].fp, "11:2")
Assert.eq(index["/b/a.epub"].md5, "m-a2")
Assert.is_false(index["/b/a.epub"].cover)
Assert.is_nil(index["/b/x.txt"])
Assert.eq(index["/b/new.pdf"].md5, "m-n")

-- 清缓存后：「试过补封面」全部复位，指纹 / md5 不动
Assert.is_true(ScanDB.resetCovers())
index = ScanDB.all()
Assert.is_false(index["/b/new.pdf"].cover)
Assert.eq(index["/b/new.pdf"].md5, "m-n")

-- 盘上清空：全删
Assert.is_true(ScanDB.save(index, {}))
Assert.is_nil(next(ScanDB.all()))

Base.close()
for _, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
