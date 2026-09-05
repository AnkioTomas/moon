--[[--
db.progress：pending_progress 表 CRUD（待上传进度）

@module tests.db.progress_spec
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
    -- extra 列要真的编解码，全局 json stub 的 encode 是会抛错的空壳
    package.preload["json"] = function()
        return {
            encode = function(t)
                local parts = {}
                for k, v in pairs(t) do
                    parts[#parts + 1] = string.format(
                        '"%s":%s', k, type(v) == "string" and '"' .. v .. '"' or tostring(v)
                    )
                end
                return "{" .. table.concat(parts, ",") .. "}"
            end,
            decode = require("support.json_stub").decode,
        }
    end
    package.loaded["json"] = nil
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

-- 假连接：prepare/exec 均记录；step/resultset 由 opts 回调供给
-- Base.query 无参数时走 conn:exec，因此 exec 也要能返回多行结果
local function makeConn(opts)
    opts = opts or {}
    local calls = {}
    local connection = {
        rowexec = function()
            if opts.changes then return opts.changes() end
            return 1
        end,
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
    package.loaded["db.base"] = nil
    package.loaded["db.progress"] = nil
    local DbBase = require("db.base")
    local ProgressDB = require("db.progress")
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
        extra = { chapter_uid = 42 },
    }))
    local q = calls[#calls - 1]
    Assert.is_true(q.sql:find("INSERT INTO pending_progress", 1, true) ~= nil)
    Assert.is_true(q.sql:find("ON CONFLICT(source_id, stable_id) DO UPDATE", 1, true) ~= nil)
    Assert.is_true(q.sql:find("chapter_title", 1, true) ~= nil)
    Assert.is_true(q.sql:find("total_pages", 1, true) ~= nil)
    -- sync_status 是绑定参数（第 12 个），不再拼进 SQL
    Assert.is_true(q.sql:find("sync_status=excluded.sync_status", 1, true) ~= nil)
    Assert.is_true(q.sql:find("updated_at=MAX(excluded.updated_at, pending_progress.updated_at)", 1, true) ~= nil)
    Assert.eq(q.argc, 12)
    Assert.eq(q.args[12], 0)
    Assert.eq(q.args[1], "moon")
    Assert.eq(q.args[2], "book'1")
    Assert.eq(q.args[3], 0.5)
    Assert.eq(q.args[4], 3)
    Assert.eq(q.args[5], "第三章")
    Assert.eq(q.args[6], 0.25)
    Assert.eq(q.args[7], 12)
    Assert.eq(q.args[8], 300)
    Assert.eq(q.args[9], "/body[1]/p[2]")
    Assert.is_true(q.args[10]:find("chapter_uid", 1, true) ~= nil) -- extra 序列化为 JSON
    Assert.eq(type(q.args[11]), "number") -- updated_at = os.time()
    Assert.is_false(q.sql:find("book'1", 1, true) ~= nil)

    local sync = calls[#calls]
    Assert.is_true(sync.sql:find("UPDATE books SET percent=", 1, true) ~= nil)
    Assert.eq(sync.args[1], 50)
    Assert.eq(sync.args[2], "moon")
    Assert.eq(sync.args[3], "book'1")

    -- 可选字段缺省时绑定 nil；非法页码（0）也落成 nil
    Assert.is_true(ProgressDB.upsert("moon", "b2", { fraction = 0.1, page = 0, total_pages = -1 }))
    q = calls[#calls - 1]
    Assert.eq(q.argc, 12)
    Assert.eq(q.args[4], nil)
    Assert.eq(q.args[5], nil)
    Assert.eq(q.args[6], nil)
    Assert.eq(q.args[7], nil)
    Assert.eq(q.args[8], nil)
    Assert.eq(q.args[9], nil)
    Assert.eq(q.args[10], nil) -- extra 缺省与空表都落 NULL

    Assert.is_true(ProgressDB.upsert("moon", "b4", { fraction = 0.1, extra = {} }))
    Assert.eq(calls[#calls - 1].args[10], nil)

    Assert.is_true(ProgressDB.upsert("moon", "b3", { fraction = 0.2, updated_at = 1234 }))
    Assert.eq(calls[#calls - 1].args[11], 1234)

    DbBase.close()
    clearMods()
end

-- ── upsertRemote：本地脏版本优先，远端进度整条丢弃 ───────
do
    -- 只有查 sync_status 的那条语句返回行，其余语句返回 nil
    local connection, calls = makeConn({
        step = function(sql)
            if sql:find("SELECT sync_status", 1, true) then
                return { 0 }, { "sync_status" }
            end
            return nil
        end,
    })
    local DbBase, ProgressDB = loadProgress(connection)
    local before = #calls

    -- 返回 true（本地版本更新算正常结果），但不写 pending_progress 也不动 books.percent
    Assert.is_true(ProgressDB.upsertRemote("moon", "b1", { fraction = 0.2 }))
    for i = before + 1, #calls do
        Assert.is_true(calls[i].sql:find("INSERT INTO pending_progress", 1, true) == nil)
        Assert.is_true(calls[i].sql:find("UPDATE books SET percent=", 1, true) == nil)
    end

    -- adoptRemote 是用户显式选择云端：无条件覆盖
    Assert.is_true(ProgressDB.adoptRemote("moon", "b1", { fraction = 0.2 }))
    local q = calls[#calls - 1]
    Assert.is_true(q.sql:find("INSERT INTO pending_progress", 1, true) ~= nil)
    Assert.eq(q.args[12], 1)

    DbBase.close()
    clearMods()
end

-- ── 远端缺时间戳不得把同步时间伪装成阅读时间 ──────────────
do
    local connection, calls = makeConn()
    local DbBase, ProgressDB = loadProgress(connection)
    Assert.is_true(ProgressDB.upsertRemote("wechat", "99", { fraction = 0.4 }))
    local q = calls[#calls - 1]
    Assert.eq(q.args[1], "wechat")
    Assert.eq(q.args[2], "99")
    Assert.eq(q.args[11], 0)

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
                { '{"chapter_uid":42}', "not json" },
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
    Assert.eq(rows[1].extra.chapter_uid, 42)
    Assert.eq(rows[1].updated_at, 1000)
    Assert.eq(rows[1].sync_status, 0)
    Assert.eq(rows[2].fraction, 0.75) -- 字符串 fraction 被 tonumber
    Assert.is_nil(rows[2].chapter_idx) -- NULL 保持 nil，不变成 0
    Assert.is_nil(rows[2].chapter_title)
    Assert.is_nil(rows[2].chapter_fraction)
    Assert.is_nil(rows[2].page)
    Assert.is_nil(rows[2].total_pages)
    Assert.is_nil(rows[2].locator)
    Assert.is_nil(rows[2].extra) -- 损坏的 JSON 不抛错，降级为 nil
    Assert.eq(rows[2].sync_status, 1)
    local q = calls[#calls]
    Assert.is_true(q.sql:find("WHERE source_id=?", 1, true) ~= nil)
    Assert.is_true(q.sql:find("ORDER BY updated_at ASC", 1, true) ~= nil)
    Assert.eq(q.argc, 1)
    Assert.eq(q.args[1], "moon")

    DbBase.close()
    clearMods()
end

-- ── recent：仅由 pending_progress 决定准入与顺序 ─────────
do
    local connection, calls = makeConn({
        resultset = function()
            return {
                { "moon", "moon" },
                { "b.epub", "a.epub" },
                { 0.8, 0.2 },
                { nil, nil }, { nil, nil }, { nil, nil },
                { nil, nil }, { nil, nil }, { nil, nil }, { nil, nil },
                { 2000, 1000 },
                { 1, 1 },
            }, 2
        end,
    })
    local DbBase, ProgressDB = loadProgress(connection)

    local rows = ProgressDB.recent("moon", 24)
    Assert.eq(rows[1].stable_id, "b.epub")
    Assert.eq(rows[1].fraction, 0.8)
    local q = calls[#calls]
    Assert.is_true(q.sql:find("FROM pending_progress p", 1, true) ~= nil)
    Assert.is_true(q.sql:find("EXISTS", 1, true) ~= nil)
    Assert.is_true(q.sql:find("b.in_library=1", 1, true) ~= nil)
    Assert.is_true(q.sql:find("last_open", 1, true) == nil)
    Assert.is_true(q.sql:find("ORDER BY p.updated_at DESC, p.stable_id ASC", 1, true) ~= nil)
    Assert.eq(q.args[1], "moon")
    Assert.eq(q.args[2], 24)

    DbBase.close()
    clearMods()
end

-- ── all()：按 source_id 查询，空结果返回 {} ──────────────
do
    local connection, calls = makeConn()
    local DbBase, ProgressDB = loadProgress(connection)

    local rows = ProgressDB.all("moon")
    Assert.eq(#rows, 0)
    local q = calls[#calls]
    Assert.is_true(q.sql:find("FROM pending_progress", 1, true) ~= nil)
    Assert.is_true(q.sql:find("WHERE source_id=?", 1, true) ~= nil)
    Assert.eq(q.argc, 1)

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
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── markSynced：revision 已过期时零行更新必须失败 ─────────
do
    local connection = makeConn({ changes = function() return 0 end })
    local DbBase, ProgressDB = loadProgress(connection)

    Assert.is_false(ProgressDB.markSynced("moon", "a.epub", 1234))

    DbBase.close()
    clearMods()
end

-- ── unsynced：状态列过滤与参数化 ───────────────────────────
do
    local connection, calls = makeConn({
        resultset = function()
            return {
                { "moon" }, { "queued.epub" }, { 0.3 },
                { nil }, { nil }, { nil }, { nil }, { nil }, { nil }, { nil },
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
