--[[--
http.cache 的 http 表 SQL：读路径只读且按当前时间过滤过期，写入顺带淘汰过期行，全参数化。

@module tests.http.cache_db_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Stubs = require("support.stubs")

package.preload["utils.paths"] = function()
    return { dbPath = function() return "unused.sqlite3" end }
end
package.preload["json"] = function()
    return {
        encode = function(v) return v end,
        decode = function(v)
            if v == "corrupt" then error("bad json") end
            return v
        end,
    }
end

-- 假连接：记录每次 prepare 的 SQL 与绑定参数；step 由 opts 回调供给
local function makeConn(opts)
    opts = opts or {}
    local calls = {}
    local connection = {
        exec = function(_, sql)
            calls[#calls + 1] = { sql = sql, argc = 0, args = {} }
        end,
        close = function() end,
        prepare = function(_, sql)
            local call = { sql = sql }
            calls[#calls + 1] = call
            return {
                bind = function(self, ...)
                    call.argc = select("#", ...)
                    call.args = { ... }
                    return self
                end,
                step = function()
                    if opts.step then return opts.step(sql) end
                    return nil
                end,
                resultset = function() return nil, 0 end,
                close = function() end,
            }
        end,
    }
    return connection, calls
end

local function loadCache(connection)
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return connection end }
    end
    for _idx, name in ipairs({ "lua-ljsqlite3/init", "utils.db", "http.cache" }) do
        package.loaded[name] = nil
    end
    local DbBase = require("utils.db")
    local Cache = require("http.cache")
    DbBase.open()
    return DbBase, Cache
end

local function fetch(Cache, key, result)
    local loads, got = 0, nil
    Cache.fetch(key, 60, function(done)
        loads = loads + 1
        done(result)
        return { cancel = function() end }
    end, function(value) got = value end)
    Stubs.flush()
    return loads, got
end

-- ── 建表：open 时登记的 http 表与过期索引 ──
do
    local connection, calls = makeConn()
    local DbBase = loadCache(connection)
    local schema = {}
    for _idx, call in ipairs(calls) do schema[#schema + 1] = call.sql end
    schema = table.concat(schema, "\n")
    Assert.is_true(schema:find("CREATE TABLE IF NOT EXISTS http", 1, true) ~= nil)
    Assert.is_true(schema:find("idx_http_expires", 1, true) ~= nil)
    DbBase.close()
end

-- ── 命中：参数化读、按当前时间过滤过期，读路径不写库 ──
do
    local connection, calls = makeConn({
        step = function(sql)
            if sql:find("SELECT value FROM http", 1, true) then return { "cached" }, { "value" } end
        end,
    })
    local DbBase, Cache = loadCache(connection)
    local mark = #calls
    local before = os.time()
    local loads, value = fetch(Cache, "https://api.example.com/x?u=1", "fresh")
    Assert.eq(loads, 0)
    Assert.eq(value, "cached")
    local q = calls[mark + 1]
    Assert.eq(q.sql, "SELECT value FROM http WHERE key=? AND expires > ? LIMIT 1;")
    Assert.eq(q.argc, 2)
    Assert.eq(q.args[1], "https://api.example.com/x?u=1")
    Assert.is_true(q.args[2] >= before, "过期判定用当前时间")
    for i = mark + 1, #calls do
        Assert.is_nil(calls[i].sql:find("DELETE FROM http", 1, true), "读路径不得写库")
        Assert.is_nil(calls[i].sql:find("api.example.com", 1, true), "用户值不拼进 SQL")
    end
    DbBase.close()
end

-- ── 未命中：先淘汰过期行，再 INSERT ... ON CONFLICT upsert，expires = now + ttl ──
do
    local connection, calls = makeConn()
    local DbBase, Cache = loadCache(connection)
    local mark = #calls
    local before = os.time()
    local loads, value = fetch(Cache, "k'1", "v\n2")
    Assert.eq(loads, 1)
    Assert.eq(value, "v\n2")
    local purge, insert
    for i = mark + 1, #calls do
        if calls[i].sql == "DELETE FROM http WHERE expires <= ?;" then purge = calls[i] end
        if calls[i].sql:find("INSERT INTO http", 1, true) then insert = calls[i] end
    end
    Assert.not_nil(purge)
    Assert.eq(type(purge.args[1]), "number")
    Assert.not_nil(insert)
    Assert.is_true(insert.sql:find("ON CONFLICT(key) DO UPDATE", 1, true) ~= nil)
    Assert.eq(insert.argc, 3)
    Assert.eq(insert.args[1], "k'1")
    Assert.eq(insert.args[2], "v\n2")
    Assert.is_true(insert.args[3] >= before + 60)
    Assert.is_nil(insert.sql:find("k'1", 1, true))
    DbBase.close()
end

-- ── JSON 损坏：参数化删除该键后当未命中 ──
do
    local connection, calls = makeConn({
        step = function(sql)
            if sql:find("SELECT value FROM http", 1, true) then return { "corrupt" }, { "value" } end
        end,
    })
    local DbBase, Cache = loadCache(connection)
    local loads = fetch(Cache, "victim'); DROP TABLE http;--", "fresh")
    Assert.eq(loads, 1)
    local deleted
    for _idx, call in ipairs(calls) do
        if call.sql == "DELETE FROM http WHERE key=?;" then deleted = call end
    end
    Assert.not_nil(deleted)
    Assert.eq(deleted.args[1], "victim'); DROP TABLE http;--")
    DbBase.close()
end

-- ── clear：无子串删全表（无参数）；有子串走 LIKE 绑定且通配符按字面量转义 ──
do
    local connection, calls = makeConn()
    local DbBase, Cache = loadCache(connection)

    Cache.clear()
    Assert.eq(calls[#calls].sql, "DELETE FROM http;")
    Assert.eq(calls[#calls].argc, 0)

    Cache.clear("api.example.com")
    local q = calls[#calls]
    Assert.eq(q.sql, [[DELETE FROM http WHERE key LIKE ? ESCAPE '\';]])
    Assert.eq(q.argc, 1)
    Assert.eq(q.args[1], "%api.example.com%")

    Cache.clear("a%b_c")
    Assert.eq(calls[#calls].args[1], "%a\\%b\\_c%")

    Cache.clear("")
    Assert.eq(calls[#calls].sql, "DELETE FROM http;")
    DbBase.close()
end
