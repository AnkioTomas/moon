--[[--
逐章目录：迁移、增量更新、快照回滚及身份生命周期。

@module tests.book.toc_db_spec
--]]
---@diagnostic disable: assign-type-mismatch

local Assert = require("support.assert")
local Config = require("support.config")
local path = Config.dir() .. "/toc_db_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(path .. suffix) end
package.preload["utils.paths"] = function()
    return { dbPath = function() return path end, sanitizeSourceId = function(id) return id end }
end
local JSON = require("support.json_stub")
package.preload["json"] = function() return JSON end
local DB = require("utils.db")
Assert.is_true(DB.exec([[CREATE TABLE toc_snapshots (
    source_id TEXT NOT NULL, stable_id TEXT NOT NULL, fetched_at INTEGER NOT NULL,
    PRIMARY KEY (source_id, stable_id));]]))
Assert.is_true(DB.exec("INSERT INTO toc_snapshots VALUES (?,?,?);", "changpei", "old-schema", 77))
local BookDB = require("book.books_db")
local TocDB = require("book.toc_db")
local Toc = require("source.toc")
local old_time, old_revision = TocDB.snapshot("changpei", "old-schema")
Assert.eq(old_time, 77, "旧快照升级不得清目录或丢拉取时间")
Assert.eq(old_revision, 1)
Assert.is_true(TocDB.put("changpei", "old-schema", { { idx = 1, uid = "old", title = "旧目录" } }, 78))
local new_time, new_revision = TocDB.snapshot("changpei", "old-schema")
Assert.eq(new_time, 78)
Assert.eq(new_revision, 2, "升级后刷新应正常递增版本")
local function same(actual, expected)
    if type(expected) ~= "table" then return Assert.eq(actual, expected) end
    Assert.eq(type(actual), "table")
    for key, value in pairs(expected) do same(actual[key], value) end
    for key in pairs(actual) do Assert.not_nil(expected[key]) end
end

local list = {
    { idx = 1, uid = "one", title = "第一章", origin = "/one", words = 1200, vip = true, paid = false,
        source_idx = 2, anchors = { { title = "小节", depth = 1, id = "s1" } }, raw = '{"id":12}' },
    { idx = 2, uid = 42, title = "第二章", words = 800, vip = false, chapterId = 42, slice = true },
}
Assert.is_true(Toc.put("jdread", "duplicate-uid", {
    { idx = 1, uid = "same", title = "一", words = 100 },
    { idx = 2, uid = "same", title = "二", words = 200 },
}))
Assert.is_true(Toc.put("jdread", "duplicate-uid", { { idx = 1, uid = "same", title = "新" } }))
Assert.eq(TocDB.read("jdread", "duplicate-uid")[1].words, 200, "重复 uid 的合并与原缓存一样取最后一项")
Assert.is_true(BookDB.setToc("jdread", "legacy", JSON.encode(list)))
same(Toc.read("jdread", "legacy"), list)
Assert.is_nil(BookDB.getToc("jdread", "legacy"), "成功迁移后不保留大载荷")
local stored, fetched_at = TocDB.read("jdread", "legacy")
same(stored, list)
Assert.is_nil(TocDB.read("wechat", "legacy"), "跨源隔离")

local encode = package.loaded.dkjson.encode
package.loaded.dkjson.encode = function() error("incremental update must not encode JSON") end
Toc.setWords("jdread", "legacy", 1, 1500)
Toc.markPaid("jdread", "legacy", "one", true)
package.loaded.dkjson.encode = encode
stored = TocDB.read("jdread", "legacy")
Assert.eq(stored[1].words, 1500)
Assert.is_true(stored[1].paid)
local _updated, after = TocDB.read("jdread", "legacy")
Assert.eq(after, fetched_at, "本地增量更新不能冒充远端拉新")

Assert.is_true(Toc.put("jdread", "legacy", {
    { idx = 1, uid = 42, title = "第二章" },
    { idx = 2, uid = "one", title = "第一章" },
}))
stored = TocDB.read("jdread", "legacy")
Assert.eq(stored[1].words, 800, "字数跟章节身份，不跟重排后的章号")
Assert.eq(stored[2].words, 1500)
Assert.is_true(stored[2].paid, "远端未给购买状态时保留已知状态")
stored[2].paid = false
Assert.is_true(TocDB.put("jdread", "legacy", stored))
stored = TocDB.read("jdread", "legacy")
Assert.is_false(stored[2].paid, "远端明确 false 时必须覆盖，不当成未知")
Assert.is_false(TocDB.put("jdread", "legacy", {
    { idx = 1, uid = "replacement", title = "替换" }, { idx = 1, uid = "duplicate", title = "重复" },
}), "写入失败整批回滚")
same(TocDB.read("jdread", "legacy"), stored)

Assert.is_true(Toc.put("wechat", "empty", {}))
local empty, at = TocDB.read("wechat", "empty")
Assert.len(empty, 0, "空目录与没有快照不同")
Assert.not_nil(at)
Assert.is_true(BookDB.renameStableId("jdread", "legacy", "renamed"))
Assert.is_nil(TocDB.read("jdread", "legacy"))
same(TocDB.read("jdread", "renamed"), stored)
Assert.is_nil(Toc.read("jdread", "legacy"), "迁身份不能留下旧内存快照")
Assert.is_true(Toc.put("jdread", "target", { { idx = 1, uid = "target", title = "目标" } }))
Assert.is_true(DB.transaction(function()
    return TocDB.moveIdentity("jdread", "renamed", "target", true)
end))
Assert.is_nil(TocDB.read("jdread", "renamed"))
Assert.eq(TocDB.read("jdread", "target")[1].uid, "target", "收编保留目标的整份快照")
Assert.is_true(BookDB.clearToc("jdread", "target"))
Assert.is_nil(TocDB.read("jdread", "target"))
Assert.is_true(BookDB.forgetSource("wechat"))
Assert.is_nil(TocDB.read("wechat", "empty"))

DB.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(path .. suffix) end
