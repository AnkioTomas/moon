--[[-- utils.db.note：notes 表完整快照写入。 --]]

local Assert = require("support.assert")

local function clearMods()
    for _, name in ipairs({
        "utils.paths", "utils.task", "lua-ljsqlite3/init", "ffi/sha2",
        "utils.db.base", "utils.db.note",
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
            step = function()
                if sql:find("PRAGMA user_version", 1, true) then
                    return { 1 }, { "user_version" }
                end
            end,
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

local Base = require("utils.db.base")
local NoteDB = require("utils.db.note")
Base.open()

Assert.is_true(NoteDB.upsert("moon", "book'1", nil, "[{}]"))
local q = calls[#calls]
Assert.is_true(q.sql:find("INSERT INTO notes", 1, true) ~= nil)
Assert.is_true(q.sql:find("ON CONFLICT(source_id, stable_id, chapter_idx)", 1, true) ~= nil)
Assert.eq(q.argc, 5)
Assert.eq(q.args[1], "moon")
Assert.eq(q.args[2], "book'1")
Assert.eq(q.args[3], 0)
Assert.eq(q.args[4], "[{}]")
Assert.eq(type(q.args[5]), "number")
Assert.is_false(q.sql:find("book'1", 1, true) ~= nil)

local before = #calls
Assert.is_false(NoteDB.upsert("", "b", nil, "[]"))
Assert.is_false(NoteDB.upsert("moon", "", nil, "[]"))
Assert.is_false(NoteDB.upsert("moon", "b", -1, "[]"))
Assert.is_false(NoteDB.upsert("moon", "b", 1.5, "[]"))
Assert.is_false(NoteDB.upsert("moon", "b", nil, nil))
Assert.eq(#calls, before)

Base.close()
clearMods()
