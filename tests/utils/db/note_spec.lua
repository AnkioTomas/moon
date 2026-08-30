--[[-- db.note：notes 表完整快照写入。 --]]

local Assert = require("support.assert")

local function clearMods()
    for _, name in ipairs({
        "utils.paths", "utils.task", "lua-ljsqlite3/init", "ffi/sha2",
        "db.base", "db.note",
        "db.book", "db.chapter", "db.http", "db.progress",
        "db.stats", "db.xray",
    }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end

local calls = {}
local connection = {
    exec = function(_, sql)
        calls[#calls + 1] = { sql = sql, args = {} }
    end,
    close = function() end,
    prepare = function(_, sql)
        local call = { sql = sql }
        calls[#calls + 1] = call
        return {
            bind = function(self, ...)
                call.args = { ... }
                call.argc = select("#", ...)
                return self
            end,
            step = function() end,
            close = function() end,
        }
    end,
}

package.preload["utils.task"] = function()
    return { inSubProcess = function() return true end }
end
package.preload["utils.paths"] = function()
    return { dbPath = function() return "unused.sqlite3" end, ensureSettings = function() end }
end
package.preload["ffi/sha2"] = function()
    return { md5 = function(s) return s end }
end
package.preload["lua-ljsqlite3/init"] = function()
    return { open = function() return connection end }
end

local Base = require("db.base")
local NoteDB = require("db.note")
Base.open()

Assert.is_true(NoteDB.upsert("moon", "book'1", nil, "[{}]"))
local q = calls[#calls]
Assert.is_true(q.sql:find("INSERT INTO notes", 1, true) ~= nil)
Assert.is_true(q.sql:find("ON CONFLICT(source_id, stable_id, chapter_idx)", 1, true) ~= nil)
Assert.eq(q.argc, 6)
Assert.eq(q.args[1], "moon")
Assert.eq(q.args[2], "book'1")
Assert.eq(q.args[3], 0)
Assert.eq(q.args[4], "[{}]")
Assert.eq(type(q.args[5]), "number")
Assert.eq(q.args[6], 0)
Assert.is_false(q.sql:find("book'1", 1, true) ~= nil)

-- get：身份参数化查询，并且 chapter_idx=nil 与整本记录的 0 对齐。
connection.prepare = function(_, sql)
    local call = { sql = sql }
    calls[#calls + 1] = call
    return {
        bind = function(self, ...)
            call.args = { ... }
            call.argc = select("#", ...)
            return self
        end,
        step = function()
            return { "moon", "book'1", 0, "[{}]", 123, 0 }, {
                "source_id", "stable_id", "chapter_idx", "payload", "updated_at", "sync_status",
            }
        end,
        close = function() end,
    }
end
local row = NoteDB.get("moon", "book'1", nil)
q = calls[#calls]
Assert.eq(q.argc, 3)
Assert.eq(q.args[1], "moon")
Assert.eq(q.args[2], "book'1")
Assert.eq(q.args[3], 0)
Assert.is_false(q.sql:find("book'1", 1, true) ~= nil)
Assert.eq(row.payload, "[{}]")
Assert.eq(row.sync_status, 0)
Base.close()
clearMods()
