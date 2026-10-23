---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- book.note_db：notes 表完整快照写入。 --]]

local Assert = require("support.assert")

local function clearMods()
    for _, name in ipairs({
        "utils.paths", "utils.task", "lua-ljsqlite3/init", "ffi/sha2",
        "utils.db", "book.note_db",
        "book.books_db", "book.chapters_db", "http.cache", "utils.event", "book.progress_db",
        "book.stats_db", "features.xray.db",
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

local Base = require("utils.db")
local NoteDB = require("book.note_db")
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
-- 章号重排：先挪到负号（新号），删掉没挪的（淘汰文章），再翻正。
calls = {}
Assert.is_true(NoteDB.remapChapters("subscribe", "3", { [1] = 2 }) and true)
local sqls = {}
for _idx, c in ipairs(calls) do
    if c.sql:find("notes") then sqls[#sqls + 1] = c end
end
Assert.matches(sqls[1].sql, "SET chapter_idx=%?")
Assert.eq(sqls[1].args[1], -2)
Assert.eq(sqls[1].args[4], 1)
Assert.matches(sqls[2].sql, "^DELETE FROM notes .-chapter_idx>0")
Assert.matches(sqls[3].sql, "chapter_idx=%-chapter_idx .-chapter_idx<0")
-- updatePayload：stale 回填只写 payload —— 脏标记与修订号都不能动，否则吃掉上传期间的新内容。
calls = {}
Assert.is_true(NoteDB.updatePayload("moon", "book'1", 3, "[snapshot]"))
q = calls[#calls]
Assert.matches(q.sql, "^UPDATE notes SET payload=%?")
Assert.is_false(q.sql:find("sync_status", 1, true) ~= nil, "不碰脏标记")
Assert.is_false(q.sql:find("updated_at", 1, true) ~= nil, "不碰修订号")
Assert.eq(q.args[1], "[snapshot]")
Assert.eq(q.args[2], "moon")
Assert.eq(q.args[3], "book'1")
Assert.eq(q.args[4], 3)
Assert.eq(q.argc, 4)
Assert.is_false(q.sql:find("book'1", 1, true) ~= nil, "身份参数化")
Base.close()
clearMods()
