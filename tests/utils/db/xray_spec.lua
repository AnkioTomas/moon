--[[-- db.xray：参数化写入。 --]]

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
package.preload["lua-ljsqlite3/init"] = function()
    return { open = function() return connection end }
end

local Base = require("db.base")
local XrayDB = require("db.xray")
Base.open()

Assert.is_true(XrayDB.upsert("moon", "b1", {
    kind = "character", name = "Mina", aliases = { "A", "B" }, role = "hero",
    description = "brave", gender = "female", occupation = "detective",
}, 10))
local call = calls[#calls]
Assert.matches(call.sql, "INSERT INTO xray_entities")
Assert.eq(call.args[1], "moon")
Assert.eq(call.args[4], "Mina")
Assert.eq(call.args[5], "A、B")
Assert.eq(call.args[6], "hero")
Assert.eq(call.args[7], "brave")
