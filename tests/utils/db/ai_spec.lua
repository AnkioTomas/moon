--[[-- utils.db.ai：AI 分析缓存使用参数化身份查询。 --]]

local Assert = require("support.assert")

local calls = {}
local connection = {
    exec = function(_, sql) calls[#calls + 1] = { sql = sql, args = {} } end,
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
package.preload["lua-ljsqlite3/init"] = function()
    return { open = function() return connection end }
end

local Base = require("utils.db.base")
local AiDB = require("utils.db.ai")
Base.open()

Assert.is_true(AiDB.upsert("moon", "book'1", 2, "ctx", 7, "{}", 99))
local call = calls[#calls]
Assert.matches(call.sql, "INSERT INTO ai_analysis")
Assert.eq(call.argc, 7)
Assert.eq(call.args[1], "moon")
Assert.eq(call.args[2], "book'1")
Assert.eq(call.args[3], 2)
Assert.eq(call.args[4], "ctx")
Assert.eq(call.args[5], 7)
Assert.eq(call.args[6], "{}")
Assert.eq(call.args[7], 99)
Assert.is_false(call.sql:find("book'1", 1, true) ~= nil)

Assert.is_false(AiDB.upsert("", "book", 0, "ctx", 1, "{}"))
Assert.is_false(AiDB.upsert("moon", "", 0, "ctx", 1, "{}"))
Assert.is_false(AiDB.upsert("moon", "book", -1, "ctx", 1, "{}"))
Assert.is_false(AiDB.upsert("moon", "book", 0, "", 1, "{}"))
Assert.is_nil(AiDB.get("moon", "book", 0, ""))

Base.close()
