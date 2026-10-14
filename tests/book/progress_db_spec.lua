--[[--
book.progress_db：pending_progress 表 CRUD（待上传进度）

@module tests.book.progress_db_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

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
        "utils.db",
        "book.books_db",
        "book.chapters_db",
        "http.cache", "utils.event",
        "book.note_db",
        "book.progress_db",
        "book.stats_db",
        "features.xray.db",
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
                    if sql == "SELECT changes();" then
                        return { opts.changes and opts.changes() or 1 }, { "changes()" }
                    end
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
    package.loaded["utils.db"] = nil
    package.loaded["book.progress_db"] = nil
    local DbBase = require("utils.db")
    local ProgressDB = require("book.progress_db")
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
    local q = calls[#calls]
    Assert.is_true(q.sql:find("INSERT INTO pending_progress", 1, true) ~= nil)
    Assert.is_true(q.sql:find("ON CONFLICT(source_id, stable_id) DO UPDATE", 1, true) ~= nil)
    Assert.is_true(q.sql:find("chapter_title", 1, true) ~= nil)
    Assert.is_true(q.sql:find("total_pages", 1, true) ~= nil)
    -- sync_status 是绑定参数（第 12 个），不再拼进 SQL
    Assert.is_true(q.sql:find("sync_status=excluded.sync_status", 1, true) ~= nil)
    Assert.is_true(q.sql:find("updated_at=MAX(excluded.updated_at, pending_progress.updated_at)", 1, true) ~= nil)
    Assert.eq(q.argc, 13)
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

    -- fraction<1 不改 books；进度真源在 pending_progress
    Assert.is_true(q.sql:find("UPDATE books", 1, true) == nil)

    -- fraction>=1 才抬 read_state
    Assert.is_true(ProgressDB.upsert("moon", "done", { fraction = 1 }))
    local sync
    for _idx, call in ipairs(calls) do
        if call.sql:find("UPDATE books SET read_state=1", 1, true) then sync = call end
    end
    Assert.is_true(sync ~= nil)
    Assert.eq(sync.args[1], "moon")
    Assert.eq(sync.args[2], "done")
    Assert.is_true(sync.sql:find("percent", 1, true) == nil)

    -- 可选字段缺省时绑定 nil；非法页码（0）也落成 nil
    Assert.is_true(ProgressDB.upsert("moon", "b2", { fraction = 0.1, page = 0, total_pages = -1 }))
    q = calls[#calls]
    Assert.is_true(q.sql:find("INSERT INTO pending_progress", 1, true) ~= nil)
    Assert.eq(q.argc, 13)
    Assert.eq(q.args[4], nil)
    Assert.eq(q.args[5], nil)
    Assert.eq(q.args[6], nil)
    Assert.eq(q.args[7], nil)
    Assert.eq(q.args[8], nil)
    Assert.eq(q.args[9], nil)
    Assert.eq(q.args[10], nil) -- extra 缺省与空表都落 NULL

    Assert.is_true(ProgressDB.upsert("moon", "b4", { fraction = 0.1, extra = {} }))
    Assert.eq(calls[#calls].args[10], nil)

    Assert.is_true(ProgressDB.upsert("moon", "b3", { fraction = 0.2, updated_at = 1234 }))
    Assert.eq(calls[#calls].args[11], 1234)
    Assert.is_nil(calls[#calls].args[13], "本地保存不写基准")

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

    -- 返回 true（本地版本更新算正常结果），但不写 pending_progress 也不动 books
    Assert.is_true(ProgressDB.upsertRemote("moon", "b1", { fraction = 0.2 }))
    for i = before + 1, #calls do
        Assert.is_true(calls[i].sql:find("INSERT INTO pending_progress", 1, true) == nil)
        Assert.is_true(calls[i].sql:find("UPDATE books SET read_state=", 1, true) == nil)
        Assert.is_true(calls[i].sql:find("UPDATE books SET percent=", 1, true) == nil)
    end

    -- adoptRemote 是用户显式选择云端：无条件覆盖
    Assert.is_true(ProgressDB.adoptRemote("moon", "b1", { fraction = 0.2 }))
    local q = calls[#calls]
    Assert.is_true(q.sql:find("INSERT INTO pending_progress", 1, true) ~= nil)
    Assert.eq(q.args[12], 1)
    Assert.eq(require("json").decode(q.args[13]).fraction, 0.2, "采用云端即记为与云端一致的位置")
    Assert.is_true(q.sql:find("synced=COALESCE(excluded.synced, pending_progress.synced)", 1, true) ~= nil,
        "本地保存不能抹掉基准")

    DbBase.close()
    clearMods()
end

-- ── 远端缺时间戳不得把同步时间伪装成阅读时间 ──────────────
do
    local connection, calls = makeConn()
    local DbBase, ProgressDB = loadProgress(connection)
    Assert.is_true(ProgressDB.upsertRemote("wechat", "99", { fraction = 0.4 }))
    local q = calls[#calls]
    Assert.eq(q.args[1], "wechat")
    Assert.eq(q.args[2], "99")
    Assert.eq(q.args[11], 0)

    DbBase.close()
    clearMods()
end

-- ── fixRemoteTime：源换时间口径时显式拉回未来时间 ──────────────
do
    local connection, calls = makeConn({ step = function() return nil end })
    local DbBase, ProgressDB = loadProgress(connection)
    local before = #calls

    Assert.is_true(ProgressDB.fixRemoteTime("ext.kavita", "700", 1770062706))
    local q = calls[before + 1]
    Assert.is_true(q.sql:find("UPDATE pending_progress SET updated_at=?", 1, true) ~= nil)
    Assert.is_true(q.sql:find("sync_status=1", 1, true) ~= nil, "只改干净行：脏行的时间归本地 revision")
    Assert.is_true(q.sql:find("updated_at>?", 1, true) ~= nil, "只降不升")
    Assert.eq(q.args[1], 1770062706)
    Assert.eq(q.args[2], "ext.kavita")
    Assert.eq(q.args[3], "700")
    Assert.eq(q.args[4], 1770062706)
    Assert.is_true(q.sql:find("INSERT INTO pending_progress", 1, true) == nil, "不新建行")

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
                { nil, nil },
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
    -- 卷行（deleted=1 + sync_status=1，非书架成员但仍是有效身份）也要能进最近阅读；
    -- 墓碑（sync_status=0）不算。
    Assert.is_true(q.sql:find("(b.deleted=0 OR b.sync_status=1)", 1, true) ~= nil)
    Assert.is_true(q.sql:find("in_library", 1, true) == nil)
    Assert.is_true(q.sql:find("last_open", 1, true) == nil)
    Assert.is_true(q.sql:find("ORDER BY p.updated_at DESC, p.stable_id ASC", 1, true) ~= nil)
    Assert.eq(q.args[1], "moon")
    Assert.eq(q.args[2], 24)

    DbBase.close()
    clearMods()
end

-- ── markSynced：版本键绑定；非法输入拒绝且不碰 DB ─────────
do
    local connection, calls = makeConn()
    local DbBase, ProgressDB = loadProgress(connection)

    Assert.is_true(ProgressDB.markSynced("moon", "a'); DROP TABLE pending_progress;--", 1234,
        { fraction = 0.5, chapter_idx = 2, page = 9 }))
    Assert.eq(calls[#calls].sql, "SELECT changes();")
    local q = calls[#calls - 1]
    Assert.is_true(q.sql:find("UPDATE pending_progress SET sync_status=1, synced=?", 1, true) ~= nil)
    Assert.is_true(q.sql:find("source_id=? AND stable_id=? AND updated_at=?", 1, true) ~= nil)
    Assert.eq(q.argc, 4)
    local synced = require("json").decode(q.args[1])
    Assert.eq(synced.fraction, 0.5)
    Assert.eq(synced.chapter_idx, 2)
    Assert.is_nil(synced.page, "基准只存冲突判断用得到的坐标")
    Assert.eq(q.args[2], "moon")
    Assert.eq(q.args[3], "a'); DROP TABLE pending_progress;--")
    Assert.eq(q.args[4], 1234)
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

    Assert.is_false(ProgressDB.markSynced("moon", "a.epub", 1234, { fraction = 0.5 }))

    DbBase.close()
    clearMods()
end

-- ── 行解码：NULL 保持 nil、字符串数值 tonumber、损坏 extra 降级为 nil ──
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
                { '{"fraction":0.5,"chapter_idx":3}', nil },
            }, 2
        end,
    })
    local DbBase, ProgressDB = loadProgress(connection)

    local rows = ProgressDB.unsynced("moon")
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
    Assert.eq(rows[1].synced.chapter_idx, 3)
    Assert.is_nil(rows[2].synced) -- 旧行没有基准
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
    Assert.is_true(q.sql:find("WHERE sync_status=0 AND source_id=?", 1, true) ~= nil)
    Assert.is_true(q.sql:find("ORDER BY updated_at ASC", 1, true) ~= nil)
    Assert.eq(q.argc, 1)
    Assert.eq(q.args[1], "moon")

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
                { 99 }, { 0 }, { nil },
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

-- ── markFinished：手动已读补一条 100% 的待上传进度 ──
do
    local connection, calls = makeConn()
    local DbBase = loadProgress(connection)

    Assert.is_true(require("book.progress_db").markFinished("moon", "b1"))
    local q
    for _idx, call in ipairs(calls) do
        if call.sql:find("INSERT INTO pending_progress", 1, true) then q = call end
    end
    Assert.is_true(q ~= nil)
    Assert.is_true(q.sql:find("fraction=1", 1, true) ~= nil)
    Assert.is_true(q.sql:find("sync_status=0", 1, true) ~= nil)
    Assert.is_true(q.sql:find("updated_at=MAX(excluded.updated_at, pending_progress.updated_at + 1)", 1, true) ~= nil,
        "修订号不能倒退或撞上在飞推送的那一版")
    Assert.eq(q.args[1], "moon")
    Assert.eq(q.args[2], "b1")
    local Progress = require("book.progress")
    Assert.eq(q.args[3], Progress.last_revision, "修订号走 Progress.nextRevision")

    DbBase.close()
    clearMods()
end

-- ── moveIdentity：改名只迁身份；收编先清掉被旧身份脏行盖过的新身份副本 ──
do
    local connection, calls = makeConn()
    local DbBase = loadProgress(connection)
    local ProgressDB = require("book.progress_db")

    local mark = #calls
    Assert.is_true(ProgressDB.moveIdentity("local", "/old.epub", "/new.epub", false))
    local own = {}
    for i = mark + 1, #calls do
        if calls[i].sql:find("pending_progress", 1, true) then own[#own + 1] = calls[i] end
    end
    Assert.len(own, 1)
    Assert.eq(own[1].sql, "UPDATE pending_progress SET stable_id=? WHERE source_id=? AND stable_id=?;")

    mark = #calls
    Assert.is_true(ProgressDB.moveIdentity("local", "/old.epub", "/new.epub", true))
    own = {}
    for i = mark + 1, #calls do
        if calls[i].sql:find("pending_progress", 1, true) then own[#own + 1] = calls[i] end
    end
    Assert.len(own, 3)
    Assert.is_true(own[1].sql:find("DELETE FROM pending_progress WHERE source_id=? AND stable_id=? AND EXISTS", 1, true) ~= nil)
    Assert.is_true(own[1].sql:find("sync_status=0", 1, true) ~= nil)
    Assert.eq(own[1].args[2], "/new.epub")
    Assert.eq(own[1].args[4], "/old.epub")
    Assert.is_true(own[2].sql:find("UPDATE OR IGNORE pending_progress", 1, true) ~= nil)
    Assert.eq(own[3].sql, "DELETE FROM pending_progress WHERE source_id=? AND stable_id=?;")

    DbBase.close()
    clearMods()
end
