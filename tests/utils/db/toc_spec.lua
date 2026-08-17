--[[--
utils.db.toc：toc 表 CRUD（在线源目录缓存，payload 不透明字符串 + fetched_at 新鲜度）

@module tests.utils.db.toc_spec
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
        "utils.db.toc",
    }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end

-- 假连接：prepare/exec 均记录；step/resultset 由 opts 回调供给
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

local function loadToc(connection)
    stubTask(true)
    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return connection end }
    end
    package.loaded["utils.db.base"] = nil
    package.loaded["utils.db.toc"] = nil
    local DbBase = require("utils.db.base")
    local TocDB = require("utils.db.toc")
    DbBase.open()
    return DbBase, TocDB
end

-- ── upsert：INSERT + ON CONFLICT，4 个绑定全参数化 ────────
do
    local connection, calls = makeConn()
    local DbBase, TocDB = loadToc(connection)

    local payload = "[{\"idx\":1}'); DROP TABLE toc;--]"
    Assert.is_true(TocDB.upsert("moon", "book'1", payload))
    local q = calls[#calls]
    Assert.is_true(q.sql:find("INSERT INTO toc", 1, true) ~= nil)
    Assert.is_true(q.sql:find("ON CONFLICT(source_id, stable_id) DO UPDATE", 1, true) ~= nil)
    Assert.eq(q.argc, 4)
    Assert.eq(q.args[1], "moon")
    Assert.eq(q.args[2], "book'1")
    Assert.eq(q.args[3], payload)
    Assert.eq(type(q.args[4]), "number") -- fetched_at = os.time()
    Assert.is_false(q.sql:find("DROP TABLE", 1, true) ~= nil)

    DbBase.close()
    clearMods()
end

-- ── upsert：非法输入拒绝且不碰 DB ────────────────────────
do
    local connection, calls = makeConn()
    local DbBase, TocDB = loadToc(connection)
    local before = #calls

    Assert.is_false(TocDB.upsert("", "b", "p"))
    Assert.is_false(TocDB.upsert(nil, "b", "p"))
    Assert.is_false(TocDB.upsert("moon", "", "p"))
    Assert.is_false(TocDB.upsert("moon", nil, "p"))
    Assert.is_false(TocDB.upsert("moon", "b", nil))
    Assert.is_false(TocDB.upsert("moon", "b", "")) -- 空串 payload 拒收
    Assert.is_false(TocDB.upsert("moon", "b", 123)) -- 非字符串 payload 拒收
    Assert.is_false(TocDB.upsert("moon", "b", { "p" }))
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── get：新鲜命中返回 payload + fetched_at，双键参数化 ────
do
    local now = os.time()
    local connection, calls = makeConn({
        step = function()
            return { "[{\"idx\":1,\"title\":\"一\"}]", now - 10 },
                { "payload", "fetched_at" }
        end,
    })
    local DbBase, TocDB = loadToc(connection)

    local payload, fetched_at = TocDB.get("moon", "b'1", 3600)
    Assert.eq(payload, "[{\"idx\":1,\"title\":\"一\"}]")
    Assert.eq(fetched_at, now - 10)
    local q = calls[#calls]
    Assert.eq(q.sql, "SELECT payload, fetched_at FROM toc WHERE source_id=? AND stable_id=? LIMIT 1;")
    Assert.eq(q.argc, 2)
    Assert.eq(q.args[1], "moon")
    Assert.eq(q.args[2], "b'1")
    Assert.is_false(q.sql:find("b'1", 1, true) ~= nil)

    DbBase.close()
    clearMods()
end

-- ── get：过期（os.time()-fetched_at >= max_age）即 miss ────
do
    local connection = makeConn({
        step = function()
            return { "old-payload", os.time() - 7200 }, { "payload", "fetched_at" }
        end,
    })
    local DbBase, TocDB = loadToc(connection)

    Assert.is_nil(TocDB.get("moon", "b1", 3600)) -- 2 小时前 > 1 小时 TTL

    DbBase.close()
    clearMods()
end

-- ── get：缺失（无行）即 miss；非法参数不碰 DB ────────────
do
    local connection, calls = makeConn()
    local DbBase, TocDB = loadToc(connection)

    Assert.is_nil(TocDB.get("moon", "missing", 3600))
    local before = #calls
    Assert.is_nil(TocDB.get("", "b", 3600))
    Assert.is_nil(TocDB.get(nil, "b", 3600))
    Assert.is_nil(TocDB.get("moon", "", 3600))
    Assert.is_nil(TocDB.get("moon", nil, 3600))
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── delete：双键绑定；非法输入拒绝且不碰 DB ──────────────
do
    local connection, calls = makeConn()
    local DbBase, TocDB = loadToc(connection)

    Assert.is_true(TocDB.delete("moon", "a'); DROP TABLE toc;--"))
    local q = calls[#calls]
    Assert.eq(q.sql, "DELETE FROM toc WHERE source_id=? AND stable_id=?;")
    Assert.eq(q.argc, 2)
    Assert.eq(q.args[1], "moon")
    Assert.eq(q.args[2], "a'); DROP TABLE toc;--")
    Assert.is_false(q.sql:find("DROP TABLE", 1, true) ~= nil)

    local before = #calls
    Assert.is_false(TocDB.delete("", "a"))
    Assert.is_false(TocDB.delete("moon", ""))
    Assert.is_false(TocDB.delete("moon", nil))
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end
