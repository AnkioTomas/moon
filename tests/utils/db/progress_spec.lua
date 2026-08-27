--[[--
utils.db.progress：pending_progress 表 CRUD（待上传进度）

@module tests.utils.db.progress_spec
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
        "utils.db.progress",
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

local function loadProgress(connection)
    stubTask(true)
    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return connection end }
    end
    package.loaded["utils.db.base"] = nil
    package.loaded["utils.db.progress"] = nil
    local DbBase = require("utils.db.base")
    local ProgressDB = require("utils.db.progress")
    DbBase.open()
    return DbBase, ProgressDB
end

-- ── upsert：INSERT + ON CONFLICT，10 个绑定全参数化 ──────
do
    local connection, calls = makeConn()
    local DbBase, ProgressDB = loadProgress(connection)

    Assert.is_true(ProgressDB.upsert("moon", "book'1", {
        fraction = "0.5", -- 字符串进度应被 tonumber
        chapter_idx = 3,
        chapter_title = "第三章",
        chapter_fraction = 0.25,
        page = 12,
        total_pages = 300,
        locator = "/body[1]/p[2]",
    }))
    local q = calls[#calls - 1]
    Assert.is_true(q.sql:find("INSERT INTO pending_progress", 1, true) ~= nil)
    Assert.is_true(q.sql:find("ON CONFLICT(source_id, stable_id) DO UPDATE", 1, true) ~= nil)
    Assert.is_true(q.sql:find("chapter_title", 1, true) ~= nil)
    Assert.is_true(q.sql:find("total_pages", 1, true) ~= nil)
    Assert.is_true(q.sql:find("sync_status=0", 1, true) ~= nil)
    Assert.eq(q.argc, 10)
    Assert.eq(q.args[1], "moon")
    Assert.eq(q.args[2], "book'1")
    Assert.eq(q.args[3], 0.5)
    Assert.eq(q.args[4], 3)
    Assert.eq(q.args[5], "第三章")
    Assert.eq(q.args[6], 0.25)
    Assert.eq(q.args[7], 12)
    Assert.eq(q.args[8], 300)
    Assert.eq(q.args[9], "/body[1]/p[2]")
    Assert.eq(type(q.args[10]), "number") -- updated_at = os.time()
    Assert.is_false(q.sql:find("book'1", 1, true) ~= nil)

    local sync = calls[#calls]
    Assert.is_true(sync.sql:find("UPDATE books SET percent=", 1, true) ~= nil)
    Assert.eq(sync.args[1], 50)
    Assert.eq(sync.args[2], "moon")
    Assert.eq(sync.args[3], "book'1")

    -- 可选字段缺省时绑定 nil；非法页码（0）也落成 nil
    Assert.is_true(ProgressDB.upsert("moon", "b2", { fraction = 0.1, page = 0, total_pages = -1 }))
    q = calls[#calls - 1]
    Assert.eq(q.argc, 10)
    Assert.eq(q.args[4], nil)
    Assert.eq(q.args[5], nil)
    Assert.eq(q.args[6], nil)
    Assert.eq(q.args[7], nil)
    Assert.eq(q.args[8], nil)
    Assert.eq(q.args[9], nil)

    Assert.is_true(ProgressDB.upsert("moon", "b3", { fraction = 0.2, updated_at = 1234 }))
    Assert.eq(calls[#calls - 1].args[10], 1234)

    DbBase.close()
    clearMods()
end

-- ── upsert：非法输入拒绝且不碰 DB ────────────────────────
do
    local connection, calls = makeConn()
    local DbBase, ProgressDB = loadProgress(connection)
    local before = #calls

    Assert.is_false(ProgressDB.upsert("", "b", { fraction = 0.1 }))
    Assert.is_false(ProgressDB.upsert(nil, "b", { fraction = 0.1 }))
    Assert.is_false(ProgressDB.upsert("moon", "", { fraction = 0.1 }))
    Assert.is_false(ProgressDB.upsert("moon", nil, { fraction = 0.1 }))
    Assert.is_false(ProgressDB.upsert("moon", "b", nil))
    Assert.is_false(ProgressDB.upsert("moon", "b", "x"))
    Assert.is_false(ProgressDB.upsert("moon", "b", {})) -- fraction 缺失
    Assert.is_false(ProgressDB.upsert("moon", "b", { fraction = "abc" })) -- fraction 非数字
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── all(source_id)：带过滤走 prepare 绑定，行映射正确 ────
do
    local connection, calls = makeConn({
        resultset = function()
            return {
                { "moon", "moon" },
                { "a.epub", "b.epub" },
                { 0.5, "0.75" },
                { 3, nil },
                { "第三章", nil },
                { 0.25, nil },
                { 12, nil },
                { 300, nil },
                { "/loc/1", nil },
                { 1000, 2000 },
                { 0, 1 },
            }, 2
        end,
    })
    local DbBase, ProgressDB = loadProgress(connection)

    local rows = ProgressDB.all("moon")
    Assert.eq(#rows, 2)
    Assert.eq(rows[1].source_id, "moon")
    Assert.eq(rows[1].stable_id, "a.epub")
    Assert.eq(rows[1].fraction, 0.5)
    Assert.eq(rows[1].chapter_idx, 3)
    Assert.eq(rows[1].chapter_title, "第三章")
    Assert.eq(rows[1].chapter_fraction, 0.25)
    Assert.eq(rows[1].page, 12)
    Assert.eq(rows[1].total_pages, 300)
    Assert.eq(rows[1].locator, "/loc/1")
    Assert.eq(rows[1].updated_at, 1000)
    Assert.eq(rows[1].sync_status, 0)
    Assert.eq(rows[2].fraction, 0.75) -- 字符串 fraction 被 tonumber
    Assert.is_nil(rows[2].chapter_idx) -- NULL 保持 nil，不变成 0
    Assert.is_nil(rows[2].chapter_title)
    Assert.is_nil(rows[2].chapter_fraction)
    Assert.is_nil(rows[2].page)
    Assert.is_nil(rows[2].total_pages)
    Assert.is_nil(rows[2].locator)
    Assert.eq(rows[2].sync_status, 1)
    local q = calls[#calls]
    Assert.is_true(q.sql:find("WHERE source_id=?", 1, true) ~= nil)
    Assert.is_true(q.sql:find("ORDER BY updated_at ASC", 1, true) ~= nil)
    Assert.eq(q.argc, 1)
    Assert.eq(q.args[1], "moon")

    DbBase.close()
    clearMods()
end

-- ── all()：无过滤走 conn:exec（无参数），空结果返回 {} ───
do
    local connection, calls = makeConn()
    local DbBase, ProgressDB = loadProgress(connection)

    local rows = ProgressDB.all()
    Assert.eq(#rows, 0)
    local q = calls[#calls]
    Assert.is_true(q.sql:find("FROM pending_progress", 1, true) ~= nil)
    Assert.is_false(q.sql:find("WHERE", 1, true) ~= nil)
    Assert.eq(q.argc, 0)

    -- 空串 source_id 等价于无过滤
    ProgressDB.all("")
    Assert.is_false(calls[#calls].sql:find("WHERE", 1, true) ~= nil)

    DbBase.close()
    clearMods()
end

-- ── markSynced：版本键绑定；非法输入拒绝且不碰 DB ─────────
do
    local connection, calls = makeConn()
    local DbBase, ProgressDB = loadProgress(connection)

    Assert.is_true(ProgressDB.markSynced("moon", "a'); DROP TABLE pending_progress;--", 1234))
    local q = calls[#calls]
    Assert.is_true(q.sql:find("UPDATE pending_progress SET sync_status=1", 1, true) ~= nil)
    Assert.is_true(q.sql:find("source_id=? AND stable_id=? AND updated_at=?", 1, true) ~= nil)
    Assert.eq(q.argc, 3)
    Assert.eq(q.args[1], "moon")
    Assert.eq(q.args[2], "a'); DROP TABLE pending_progress;--")
    Assert.eq(q.args[3], 1234)
    Assert.is_false(q.sql:find("DROP TABLE", 1, true) ~= nil)

    local before = #calls
    Assert.is_false(ProgressDB.markSynced("", "a", 1))
    Assert.is_false(ProgressDB.markSynced("moon", "", 1))
    Assert.is_false(ProgressDB.markSynced("moon", nil, 1))
    Assert.is_false(ProgressDB.markSynced("moon", "a", nil))
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── unsynced：状态列过滤与参数化 ───────────────────────────
do
    local connection, calls = makeConn({
        resultset = function()
            return {
                { "moon" }, { "queued.epub" }, { 0.3 },
                { nil }, { nil }, { nil }, { nil }, { nil }, { nil },
                { 99 }, { 0 },
            }, 1
        end,
    })
    local DbBase, ProgressDB = loadProgress(connection)

    local rows = ProgressDB.unsynced("moon")
    Assert.len(rows, 1)
    Assert.eq(rows[1].stable_id, "queued.epub")
    Assert.eq(rows[1].sync_status, 0)
    local q = calls[#calls]
    Assert.is_true(q.sql:find("sync_status=0", 1, true) ~= nil)
    Assert.eq(q.args[1], "moon")

    DbBase.close()
    clearMods()
end
