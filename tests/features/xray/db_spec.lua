--[[-- features.xray.db：参数化写入。 --]]

local Assert = require("support.assert")

local calls = {}
local fail_commit = false
local fail_statement
local connection = {
    exec = function(connection, sql)
        calls[#calls + 1] = { sql = sql, args = {} }
        if fail_commit and sql == "COMMIT;" then error("commit failed") end
    end,
    close = function() end,
    prepare = function(connection, sql)
        if fail_statement and sql:find(fail_statement, 1, true) then error("statement failed") end
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

local Base = require("utils.db")
local XrayDB = require("features.xray.db")
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

fail_commit = true
Assert.is_false(XrayDB.replace("moon", "b1", {}))
Assert.eq(calls[#calls].sql, "ROLLBACK;")

-- 删除：实体与墓碑在同一事务里写入，名字和别名都留墓碑
fail_commit = false
calls = {}
Assert.is_true(XrayDB.remove("moon", "b1", { kind = "character", name = " Mina ", aliases = { "Harker" } }))
Assert.eq(calls[1].sql, "BEGIN IMMEDIATE;")
Assert.matches(calls[2].sql, "DELETE FROM xray_entities")
local tombs = {}
for _idx, c in ipairs(calls) do
    if c.sql:find("xray_removed", 1, true) and c.sql:find("INSERT", 1, true) then tombs[#tombs + 1] = c.args[4] end
end
Assert.eq(table.concat(tombs, ","), "mina,harker")
Assert.eq(calls[#calls].sql, "COMMIT;")

-- 显式重生前清墓碑：整本书的 xray_removed 一把删掉
calls = {}
Assert.is_true(XrayDB.clearRemoved("moon", "b1"))
Assert.matches(calls[#calls].sql, "DELETE FROM xray_removed")
Assert.eq(calls[#calls].args[1], "moon")
Assert.eq(calls[#calls].args[2], "b1")

-- 撕墓碑走同一份名单，但不另起事务：外层 BookDB.remove 已经在事务里。
calls = {}
Assert.is_true(XrayDB.removeIdentity("moon", "b1"))
local removed = {}
for _idx, c in ipairs(calls) do
    removed[#removed + 1] = c.sql:match("^DELETE FROM ([%w_]+)")
end
Assert.eq(table.concat(removed, ","), "xray_entities,xray_scan,xray_removed,xray_chapter")
Assert.len(calls, 4, "撕墓碑不另起事务")

-- 重置所有 X-Ray 数据在同一事务内完成，单表失败时不留下部分清理结果。
calls = {}
Assert.is_true(XrayDB.reset("moon", "b1"))
Assert.eq(calls[1].sql, "BEGIN IMMEDIATE;")
local reset_tables = {}
for _idx, c in ipairs(calls) do
    local tbl = c.sql:match("^DELETE FROM ([%w_]+)")
    if tbl then reset_tables[#reset_tables + 1] = tbl end
end
Assert.eq(table.concat(reset_tables, ","), "xray_entities,xray_scan,xray_removed,xray_chapter")
Assert.eq(calls[#calls].sql, "COMMIT;")

calls = {}
fail_statement = "DELETE FROM xray_removed"
Assert.is_false(XrayDB.reset("moon", "b1"))
Assert.eq(calls[#calls].sql, "ROLLBACK;")
fail_statement = nil

return true
