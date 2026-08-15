--[[--
utils.db.open：opens 表 CRUD（recentBySource 已在 db_spec 覆盖）

@module tests.utils.db.open_spec
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
        "utils.db.base",
        "utils.db.open",
    }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end

-- 假连接：prepare/exec 均记录；step/resultset 由 opts 回调供给
-- Base.query 无参数时走 conn:exec，因此 exec 也要能返回多行结果
local function makeConn(opts)
    opts = opts or {}
    local calls = {}
    local connection = {
        exec = function(_, sql)
            calls[#calls + 1] = { sql = sql, argc = 0, args = {} }
            if opts.exec then
                return opts.exec(sql)
            end
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
                    if opts.resultset then
                        return opts.resultset(sql)
                    end
                    return nil, 0
                end,
                close = function() end,
            }
        end,
    }
    return connection, calls
end

local function loadOpen(connection)
    stubTask(true)
    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return connection end }
    end
    package.loaded["utils.db.base"] = nil
    package.loaded["utils.db.open"] = nil
    local DbBase = require("utils.db.base")
    local OpenDB = require("utils.db.open")
    DbBase.open()
    return DbBase, OpenDB
end

-- ── upsert：INSERT + ON CONFLICT，5 个绑定全参数化 ───────
do
    local connection, calls = makeConn()
    local DbBase, OpenDB = loadOpen(connection)

    Assert.is_true(OpenDB.upsert({
        source_id = "local",
        stable_id = "/books/a'1.epub",
        path = "/real/path/a1.epub",
        chapter_idx = 7,
        last_open = 1234567,
    }))
    local q = calls[#calls]
    Assert.is_true(q.sql:find("INSERT INTO opens", 1, true) ~= nil)
    Assert.is_true(q.sql:find("ON CONFLICT(source_id, stable_id) DO UPDATE", 1, true) ~= nil)
    Assert.eq(q.argc, 5)
    Assert.eq(q.args[1], "local")
    Assert.eq(q.args[2], "/books/a'1.epub")
    Assert.eq(q.args[3], "/real/path/a1.epub")
    Assert.eq(q.args[4], 7)
    Assert.eq(q.args[5], 1234567)
    Assert.is_false(q.sql:find("/real/path/a1.epub", 1, true) ~= nil)

    -- chapter_idx / last_open 缺省：nil 绑定 + os.time()
    Assert.is_true(OpenDB.upsert({
        source_id = "local",
        stable_id = "/books/b.epub",
        path = "/real/path/b.epub",
    }))
    q = calls[#calls]
    Assert.eq(q.argc, 5)
    Assert.eq(q.args[4], nil)
    Assert.eq(type(q.args[5]), "number")

    DbBase.close()
    clearMods()
end

-- ── upsert：非法输入拒绝且不碰 DB ────────────────────────
do
    local connection, calls = makeConn()
    local DbBase, OpenDB = loadOpen(connection)
    local before = #calls

    Assert.is_false(OpenDB.upsert(nil))
    Assert.is_false(OpenDB.upsert("x"))
    Assert.is_false(OpenDB.upsert({ stable_id = "s", path = "/p" })) -- 缺 source_id
    Assert.is_false(OpenDB.upsert({ source_id = "", stable_id = "s", path = "/p" }))
    Assert.is_false(OpenDB.upsert({ source_id = "local", path = "/p" })) -- 缺 stable_id
    Assert.is_false(OpenDB.upsert({ source_id = "local", stable_id = "", path = "/p" }))
    Assert.is_false(OpenDB.upsert({ source_id = "local", stable_id = "s" })) -- 缺 path
    Assert.is_false(OpenDB.upsert({ source_id = "local", stable_id = "s", path = "" }))
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── get：命中映射；未命中 nil；非法输入不碰 DB ───────────
do
    local connection, calls = makeConn({
        step = function()
            return { "local", "/books/a.epub", "/real/a.epub", 3, 9000 },
                { "source_id", "stable_id", "path", "chapter_idx", "last_open" }
        end,
    })
    local DbBase, OpenDB = loadOpen(connection)

    local row = OpenDB.get("local", "/books/a.epub")
    Assert.not_nil(row)
    Assert.eq(row.source_id, "local")
    Assert.eq(row.stable_id, "/books/a.epub")
    Assert.eq(row.path, "/real/a.epub")
    Assert.eq(row.chapter_idx, 3)
    Assert.eq(row.last_open, 9000)
    local q = calls[#calls]
    Assert.is_true(q.sql:find("FROM opens WHERE source_id=? AND stable_id=? LIMIT 1;", 1, true) ~= nil)
    Assert.eq(q.argc, 2)
    Assert.eq(q.args[1], "local")
    Assert.eq(q.args[2], "/books/a.epub")

    DbBase.close()
    clearMods()
end

-- ── get：未命中 nil；chapter_idx NULL 保持 nil ───────────
do
    local connection, calls = makeConn({
        step = function()
            return { "local", "/books/a.epub", "/real/a.epub", nil, "9000" },
                { "source_id", "stable_id", "path", "chapter_idx", "last_open" }
        end,
    })
    local DbBase, OpenDB = loadOpen(connection)

    local row = OpenDB.get("local", "/books/a.epub")
    Assert.is_nil(row.chapter_idx) -- NULL 不变成 0
    Assert.eq(row.last_open, 9000) -- 字符串时间戳被 tonumber

    local before = #calls
    Assert.is_nil(OpenDB.get("", "s"))
    Assert.is_nil(OpenDB.get("local", ""))
    Assert.is_nil(OpenDB.get("local", nil))
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── get：未命中（无行）返回 nil ──────────────────────────
do
    local connection = makeConn()
    local DbBase, OpenDB = loadOpen(connection)
    Assert.is_nil(OpenDB.get("local", "missing"))
    DbBase.close()
    clearMods()
end

-- ── getByPath：按物理路径反查身份 ────────────────────────
do
    local connection, calls = makeConn({
        step = function()
            return { "moon", "stable-1", "/real/p.epub", 2, 8000 },
                { "source_id", "stable_id", "path", "chapter_idx", "last_open" }
        end,
    })
    local DbBase, OpenDB = loadOpen(connection)

    local row = OpenDB.getByPath("/real/p.epub")
    Assert.not_nil(row)
    Assert.eq(row.source_id, "moon")
    Assert.eq(row.stable_id, "stable-1")
    Assert.eq(row.path, "/real/p.epub")
    Assert.eq(row.chapter_idx, 2)
    Assert.eq(row.last_open, 8000)
    local q = calls[#calls]
    Assert.is_true(q.sql:find("FROM opens WHERE path=? LIMIT 1;", 1, true) ~= nil)
    Assert.eq(q.argc, 1)
    Assert.eq(q.args[1], "/real/p.epub")
    Assert.is_false(q.sql:find("/real/p.epub", 1, true) ~= nil)

    DbBase.close()
    clearMods()
end

-- ── getByPath：非法路径不碰 DB ───────────────────────────
do
    local connection, calls = makeConn()
    local DbBase, OpenDB = loadOpen(connection)

    Assert.is_nil(OpenDB.getByPath("/missing.epub")) -- 无行
    local before = #calls
    Assert.is_nil(OpenDB.getByPath(nil))
    Assert.is_nil(OpenDB.getByPath(""))
    Assert.is_nil(OpenDB.getByPath(42))
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── all：走 conn:exec（无参数），行映射正确 ──────────────
do
    local connection, calls = makeConn({
        exec = function(sql)
            if sql:find("FROM opens", 1, true) then
                return {
                    { "local", "moon" },
                    { "/a.epub", "stable-2" },
                    { "/real/a.epub", "/real/b.epub" },
                    { 3, nil },
                    { 9000, "8000" },
                }, 2
            end
        end,
    })
    local DbBase, OpenDB = loadOpen(connection)

    local rows = OpenDB.all()
    Assert.eq(#rows, 2)
    Assert.eq(rows[1].source_id, "local")
    Assert.eq(rows[1].stable_id, "/a.epub")
    Assert.eq(rows[1].path, "/real/a.epub")
    Assert.eq(rows[1].chapter_idx, 3)
    Assert.eq(rows[1].last_open, 9000)
    Assert.eq(rows[2].source_id, "moon")
    Assert.is_nil(rows[2].chapter_idx)
    Assert.eq(rows[2].last_open, 8000)
    local q = calls[#calls]
    Assert.is_true(q.sql:find("FROM opens", 1, true) ~= nil)
    Assert.eq(q.argc, 0)

    DbBase.close()
    clearMods()
end

-- ── all：空表返回 {} ─────────────────────────────────────
do
    local connection = makeConn()
    local DbBase, OpenDB = loadOpen(connection)
    Assert.eq(#OpenDB.all(), 0)
    DbBase.close()
    clearMods()
end

-- ── delete：双键绑定；非法输入拒绝 ───────────────────────
do
    local connection, calls = makeConn()
    local DbBase, OpenDB = loadOpen(connection)

    Assert.is_true(OpenDB.delete("local", "/a'); DROP TABLE opens;--"))
    local q = calls[#calls]
    Assert.eq(q.sql, "DELETE FROM opens WHERE source_id=? AND stable_id=?;")
    Assert.eq(q.argc, 2)
    Assert.eq(q.args[1], "local")
    Assert.eq(q.args[2], "/a'); DROP TABLE opens;--")
    Assert.is_false(q.sql:find("DROP TABLE", 1, true) ~= nil)

    local before = #calls
    Assert.is_false(OpenDB.delete("", "/a"))
    Assert.is_false(OpenDB.delete("local", ""))
    Assert.is_false(OpenDB.delete("local", nil))
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── clear：无参数删全表 ──────────────────────────────────
do
    local connection, calls = makeConn()
    local DbBase, OpenDB = loadOpen(connection)

    Assert.is_true(OpenDB.clear())
    local q = calls[#calls]
    Assert.eq(q.sql, "DELETE FROM opens;")
    Assert.eq(q.argc, 0)

    DbBase.close()
    clearMods()
end
