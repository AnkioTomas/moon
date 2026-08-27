--[[-- utils.db.xray：参数化写入。 --]]

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
local XrayDB = require("utils.db.xray")
Base.open()

Assert.is_true(XrayDB.upsertEntity("moon", "b1", "character", "Mina", "[]", "{}", 10))
local call = calls[#calls]
Assert.matches(call.sql, "INSERT INTO xray_entities")
Assert.eq(call.args[1], "moon")
Assert.eq(call.args[4], "Mina")

Assert.is_false(XrayDB.upsertEntity("", "b1", "character", "Mina", "[]", "{}"))
