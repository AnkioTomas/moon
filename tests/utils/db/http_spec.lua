--[[--

db.http：http 表 CRUD（HTTP GET 响应缓存）

@module tests.db.http_spec
--]]

local Assert = require("support.assert")

local function stubTask(in_sub)
    package.preload["utils.task"] = function()
        return {
            inSubProcess = function()
                return in_sub
            end,
        }
    end
    package.loaded["utils.task"] = nil
end

local function stubDbDeps()
    package.preload["utils.paths"] = function()
        return {
            dbPath = function() return "unused.sqlite3" end,
            ensureSettings = function() end,
            sanitizeSourceId = function(id) return id end,
        }
    end
    package.preload["ffi/sha2"] = function()
        return { md5 = function(s) return s end }
    end
end

local function clearMods()
    for _, name in ipairs({
        "utils.paths",
        "utils.task",
        "lua-ljsqlite3/init",
        "ffi/sha2",
        "db.base",
        "db.book",
        "db.chapter",
        "db.http",
        "db.note",
        "db.progress",
        "db.stats",
        "db.xray",
    }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end

-- 假连接：记录每次 prepare 的 SQL 与绑定参数；step/resultset 由 opts 回调供给
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
                    if opts.step then
                        return opts.step(sql)
                    end
                    return nil
                end,
                resultset = function()
                    return nil, 0
                end,
                close = function() end,
            }
        end,
    }
    return connection, calls
end

local function loadHttp(connection)
    stubTask(true)
    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return connection end }
    end
    package.loaded["db.base"] = nil
    package.loaded["db.http"] = nil
    local DbBase = require("db.base")
    local HttpDB = require("db.http")
    DbBase.open()
    return DbBase, HttpDB
end

-- ── get：命中返回 (value, expires)，全参数化 ─────────────
do
    local connection, calls = makeConn({
        step = function()
            return { '{"a":1}', os.time() + 3600 }, { "value", "expires" }
        end,
    })
    local DbBase, HttpDB = loadHttp(connection)

    local value, expires = HttpDB.get("https://api.example.com/x?u=1")
    Assert.eq(value, '{"a":1}')
    Assert.eq(expires > os.time(), true)
    local q = calls[#calls]
    Assert.is_true(q.sql:find("SELECT value, expires FROM http WHERE key=?", 1, true) ~= nil)
    Assert.eq(q.argc, 1)
    Assert.eq(q.args[1], "https://api.example.com/x?u=1")
    -- 用户值不拼进 SQL 文本
    Assert.is_false(q.sql:find("api.example.com", 1, true) ~= nil)

    DbBase.close()
    clearMods()
end

-- ── get：未命中返回 nil ──────────────────────────────────
do
    local connection = makeConn() -- step 恒 nil = 未命中
    local DbBase, HttpDB = loadHttp(connection)

    Assert.is_nil(HttpDB.get("missing"))

    DbBase.close()
    clearMods()
end

-- ── get：读取前批量删除所有过期条目 ─────────────────────
do
    local deleted = false
    local connection, calls = makeConn({
        step = function(sql)
            if sql:find("DELETE FROM http WHERE expires", 1, true) then
                deleted = true
                return
            end
            if sql:find("SELECT value, expires", 1, true) then
                if deleted then return nil, 0 end
                return { "expired", os.time() - 1 }, { "value", "expires" }
            end
        end,
    })
    local DbBase, HttpDB = loadHttp(connection)

    local value = HttpDB.get("expired-key")
    Assert.is_nil(value)
    local q
    for _, call in ipairs(calls) do
        if call.sql == "DELETE FROM http WHERE expires <= ?;" then q = call break end
    end
    Assert.not_nil(q)
    Assert.eq(q.sql, "DELETE FROM http WHERE expires <= ?;")
    Assert.eq(q.argc, 1)
    Assert.eq(type(q.args[1]), "number")
    Assert.is_true(calls[#calls].sql:find("SELECT value, expires", 1, true) ~= nil)

    DbBase.close()
    clearMods()
end

-- ── set：INSERT + ON CONFLICT upsert，expires 强转 number ─
do
    local connection, calls = makeConn()
    local DbBase, HttpDB = loadHttp(connection)

    Assert.is_true(HttpDB.set("k'1", "v\n2", "999"))
    local q = calls[#calls]
    Assert.is_true(q.sql:find("INSERT INTO http", 1, true) ~= nil)
    Assert.is_true(q.sql:find("ON CONFLICT(key) DO UPDATE", 1, true) ~= nil)
    Assert.eq(q.argc, 3)
    Assert.eq(q.args[1], "k'1")
    Assert.eq(q.args[2], "v\n2")
    Assert.eq(q.args[3], 999) -- 字符串 expires 被 tonumber
    Assert.is_false(q.sql:find("k'1", 1, true) ~= nil)

    -- expires 非数字 → 0
    Assert.is_true(HttpDB.set("k2", "v", nil))
    Assert.eq(calls[#calls].args[3], 0)

    DbBase.close()
    clearMods()
end

-- ── delete：参数化删除 ───────────────────────────────────
do
    local connection, calls = makeConn()
    local DbBase, HttpDB = loadHttp(connection)

    local key = "victim'); DROP TABLE http;--"
    Assert.is_true(HttpDB.delete(key))
    local q = calls[#calls]
    Assert.eq(q.sql, "DELETE FROM http WHERE key=?;")
    Assert.eq(q.argc, 1)
    Assert.eq(q.args[1], key)
    Assert.is_false(q.sql:find("DROP TABLE", 1, true) ~= nil)

    DbBase.close()
    clearMods()
end

-- ── clear：无子串删全表（无参数）；有子串走 LIKE 绑定 ────
do
    local connection, calls = makeConn()
    local DbBase, HttpDB = loadHttp(connection)

    Assert.is_true(HttpDB.clear())
    local q = calls[#calls]
    Assert.eq(q.sql, "DELETE FROM http;")
    Assert.eq(q.argc, 0) -- 全清不带任何参数

    Assert.is_true(HttpDB.clear("api.example.com"))
    q = calls[#calls]
    Assert.eq(q.sql, [[DELETE FROM http WHERE key LIKE ? ESCAPE '\';]])
    Assert.eq(q.argc, 1)
    Assert.eq(q.args[1], "%api.example.com%")
    Assert.is_false(q.sql:find("api.example.com", 1, true) ~= nil)

    -- LIKE 通配符按字面量转义（\ 转义 + ESCAPE 子句），不误删
    Assert.is_true(HttpDB.clear("a%b_c"))
    q = calls[#calls]
    Assert.eq(q.args[1], "%a\\%b\\_c%")

    -- 空串等价于无子串（删全表）
    Assert.is_true(HttpDB.clear(""))
    Assert.eq(calls[#calls].sql, "DELETE FROM http;")

    DbBase.close()
    clearMods()
end
