--[[--
book.stats_db：sessionRows 取本机逐页记录（忽略云端桶、按时间截断）；
progressBooks 区分读完 / 在读（手动已读、进度 ≥99%、标未读不算读完）。真实 sqlite 执行。

@module tests.book.stats_db_insight_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

local db_path = Config.dir() .. "/stats_db_insight_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return db_path end,
        ensureSettings = function() end,
        sanitizeSourceId = function(id) return id end,
    }
end
package.loaded["utils.settings"] = nil
package.preload["utils.settings"] = function()
    return { getSource = function() return {} end }
end
for _idx, name in ipairs({ "utils.db", "book.stats_db" }) do package.loaded[name] = nil end

local Base = require("utils.db")
local StatsDB = require("book.stats_db")
Assert.not_nil(Base.open())

local function add(stable_id, record_type, start_time, duration)
    Assert.is_true(StatsDB.add({ source_id = "local", stable_id = stable_id, record_type = record_type,
        page = 1, start_time = start_time, duration = duration, total_pages = 0 }, StatsDB.SYNCED))
end
local function book(stable_id, state, fraction, updated)
    Assert.is_true(Base.exec(
        [[INSERT INTO books (source_id, stable_id, title, authors, category, deleted, read_state)
          VALUES ('local', ?, ?, 'A', 'C', 0, ?);]], stable_id, stable_id, state))
    if fraction then
        Assert.is_true(Base.exec(
            [[INSERT INTO pending_progress (source_id, stable_id, fraction, updated_at) VALUES ('local', ?, ?, ?);]],
            stable_id, fraction, updated or 0))
    end
end

add("a", "page", 1000, 60)
add("a", "page", 5000, 30)
add("a", "day", 2000, 999)
local rows = StatsDB.sessionRows("local", 1500)
Assert.len(rows, 1, "云端日桶与 from 之前的记录不算")
Assert.eq(rows[1].start_time, 5000)
Assert.eq(rows[1].duration, 30)

book("done", 0, 1.0, 777)
book("manual", 1, 0.2)
book("unread", 0, 0.995)
book("half", 0, 0.5)
book("none", 0, nil)
Assert.is_true(Base.exec("UPDATE books SET read_state=2 WHERE stable_id='unread';"))
add("done", "page", 9000, 120)

local finished = StatsDB.progressBooks("local", true)
local ids = {}
for _idx, b in ipairs(finished) do ids[b.stable_id] = b end
Assert.not_nil(ids.done)
Assert.not_nil(ids.manual)
Assert.is_nil(ids.unread, "标未读不算读完")
Assert.is_nil(ids.half)
Assert.eq(ids.done.last_time, 9000, "最后阅读时间取本机记录")
Assert.eq(ids.done.seconds, 120)
Assert.eq(ids.manual.last_time, 0, "没记录没进度时间时为 0")

local reading = StatsDB.progressBooks("local", false, 5)
Assert.len(reading, 1)
Assert.eq(reading[1].stable_id, "half")

return true
