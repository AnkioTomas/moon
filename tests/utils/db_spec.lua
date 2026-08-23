--[[--
utils.db：open 仅子进程 + wipeIfStale 清库重建 + reading_stats CRUD

@module tests.utils.db_spec
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
        "utils.db.book",
        "utils.db.stats",
    }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end

-- ── 主进程 open 应成功（WAL 模式 + busy_timeout，读操作安全）───
do
    stubTask(false)
    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return { exec = function() end, close = function() end } end }
    end
    package.loaded["utils.db.base"] = nil

    local DbBase = require("utils.db.base")
    local ok, conn = pcall(DbBase.open)
    Assert.is_true(ok)
    Assert.is_true(conn ~= nil)
    clearMods()
end

-- ── 子进程 open / close ─────────────────────────────────
do
    local closed = 0
    local opened = 0

    stubTask(true)
    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return {
            open = function()
                opened = opened + 1
                return {
                    exec = function() end,
                    close = function()
                        closed = closed + 1
                    end,
                    rowexec = function() return nil end,
                }
            end,
        }
    end
    package.loaded["utils.db.base"] = nil

    local DbBase = require("utils.db.base")
    Assert.is_true(DbBase.open() ~= nil)
    Assert.eq(opened, 1)
    Assert.is_true(DbBase.open() ~= nil)
    Assert.eq(opened, 1)
    DbBase.close()
    Assert.eq(closed, 1)
    clearMods()
end

-- ── 参数必须绑定，不得拼进 SQL 文本 ─────────────────────
do
    local calls = {}
    local connection = {
        exec = function() end,
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
                    if sql:find("SELECT", 1, true) then
                        return { "line1\nline2's", nil, 3 }, { "text", "nullable", "number" }
                    end
                    return nil
                end,
                close = function() end,
            }
        end,
    }

    stubTask(true)
    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return connection end }
    end
    package.loaded["utils.db.base"] = nil

    local DbBase = require("utils.db.base")
    DbBase.open()
    -- open 时 wipeIfStale 先查 user_version：首个 prepare 固定是这条 PRAGMA
    Assert.eq(calls[1].sql, "PRAGMA user_version;")
    local text = "line1\nline2's"
    Assert.is_true(DbBase.exec("INSERT INTO sample VALUES (?,?,?)", text, nil, 3) ~= nil)
    Assert.eq(calls[2].sql, "INSERT INTO sample VALUES (?,?,?)")
    Assert.eq(calls[2].argc, 3)
    Assert.eq(calls[2].args[1], text)
    Assert.eq(calls[2].args[2], nil)
    Assert.eq(calls[2].args[3], 3)

    local got_text, got_nil, got_number = DbBase.rowexec(
        "SELECT text, nullable, number FROM sample WHERE text=?",
        text
    )
    Assert.eq(got_text, text)
    Assert.eq(got_nil, nil)
    Assert.eq(got_number, 3)
    Assert.eq(calls[3].args[1], text)

    DbBase.close()
    clearMods()
end

-- ── reading_stats：add / count / all / delete 全参数化 ──
do
    local calls = {}
    local connection = {
        exec = function() end,
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
                    if sql:find("COUNT", 1, true) then
                        return { 2 }, { "COUNT(*)" }
                    end
                    return nil
                end,
                resultset = function()
                    return {
                        { 7, 8 },
                        { "a.epub", "b.epub" },
                        { 3, 4 },
                        { 1000, 2000 },
                        { 30, 45 },
                        { 300, 400 },
                        { 0, 1 },
                    }, 2
                end,
                close = function() end,
            }
        end,
    }

    stubTask(true)
    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return connection end }
    end
    package.loaded["utils.db.base"] = nil
    package.loaded["utils.db.stats"] = nil

    local DbBase = require("utils.db.base")
    local StatsDB = require("utils.db.stats")
    DbBase.open()

    Assert.is_true(StatsDB.add({
        source_id = "moon",
        stable_id = "a.epub",
        page = 3,
        start_time = 1000,
        duration = 30,
        total_pages = 300,
    }))
    local insert = calls[#calls]
    Assert.is_true(insert.sql:find("INSERT INTO reading_stats", 1, true) ~= nil)
    Assert.eq(insert.argc, 7)
    Assert.eq(insert.args[1], "moon")
    Assert.eq(insert.args[2], "a.epub")
    Assert.eq(insert.args[4], 1000)
    Assert.eq(insert.args[7], 0)

    -- 非法输入在碰 DB 前拒绝
    Assert.is_false(StatsDB.add({ source_id = "moon", stable_id = "", start_time = 1, duration = 1 }))
    Assert.is_false(StatsDB.add({ source_id = "moon", stable_id = "a", start_time = 1, duration = 0 }))

    Assert.eq(StatsDB.countBySource("moon"), 2)

    local rows = StatsDB.allBySource("moon")
    Assert.eq(#rows, 2)
    Assert.eq(rows[1].id, 7)
    Assert.eq(rows[1].stable_id, "a.epub")
    Assert.eq(rows[1].start_time, 1000)
    Assert.eq(rows[2].duration, 45)
    Assert.eq(rows[2].sync_status, 1)

    local pending = StatsDB.unsyncedBySource("moon")
    Assert.eq(#pending, 2)
    Assert.is_true(StatsDB.markSynced({ 7, 8 }))
    local updates = 0
    for _, c in ipairs(calls) do
        if c.sql:find("UPDATE reading_stats SET sync_status=1", 1, true) then
            updates = updates + 1
        end
    end
    Assert.eq(updates, 2)

    DbBase.close()
    clearMods()
end

-- ── books 表：listBySource 分页/筛选/搜索 + 分类/系列列表 ──
do
    local calls = {}
    local connection = {
        exec = function() end,
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
                    if sql:find("COUNT", 1, true) then
                        return { 7 }, { "COUNT(*)" }
                    end
                    return nil
                end,
                resultset = function()
                    if sql:find("DISTINCT category", 1, true) then
                        return { { "sub", "zeta" } }, 2
                    end
                    if sql:find("DISTINCT series", 1, true) then
                        return { { "第一辑", "第二辑" } }, 2
                    end
                    return {
                        { "/books/a.epub" },
                        { "书名" },
                        { "作者" },
                        { 42 },
                        { "sub" },
                        { "第一辑" },
                        { "介绍" },
                        { 1000 },
                    }, 1
                end,
                close = function() end,
            }
        end,
    }

    stubTask(true)
    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return connection end }
    end
    package.loaded["utils.db.base"] = nil
    package.loaded["utils.db.book"] = nil

    local DbBase = require("utils.db.base")
    local BookDB = require("utils.db.book")
    DbBase.open()

    -- 无筛选：仅 source_id；LIMIT/OFFSET 绑定
    local rows, count = BookDB.listBySource("local", { limit = 24, offset = 48 })
    Assert.eq(count, 7)
    Assert.eq(#rows, 1)
    Assert.eq(rows[1].stable_id, "/books/a.epub")
    Assert.eq(rows[1].title, "书名")
    Assert.eq(rows[1].percent, 42)
    Assert.eq(rows[1].series, "第一辑")
    local count_q = calls[#calls - 1]
    Assert.is_true(count_q.sql:find("WHERE source_id=%?", 1) ~= nil or count_q.sql:find("source_id=?", 1, true) ~= nil)
    Assert.is_false(count_q.sql:find("category=", 1, true) ~= nil)
    local list_q = calls[#calls]
    Assert.is_true(list_q.sql:find("LIMIT ? OFFSET ?", 1, true) ~= nil)
    Assert.eq(list_q.args[#list_q.args - 1], 24)
    Assert.eq(list_q.args[#list_q.args], 48)

    -- 分类 + 系列 + 搜索：AND 条件与 LIKE 参数
    calls = {}
    rows, count = BookDB.listBySource("local", {
        category = "sub",
        series = "第一辑",
        search = "鲁",
        limit = 10,
        offset = 0,
    })
    Assert.eq(count, 7)
    count_q = calls[1]
    Assert.is_true(count_q.sql:find("AND b.category=?", 1, true) ~= nil)
    Assert.is_true(count_q.sql:find("AND b.series=?", 1, true) ~= nil)
    Assert.is_true(count_q.sql:find("b.title LIKE ?", 1, true) ~= nil)
    Assert.eq(count_q.args[1], "local")
    Assert.eq(count_q.args[2], "sub")
    Assert.eq(count_q.args[3], "第一辑")
    Assert.eq(count_q.args[4], "%鲁%")
    Assert.eq(count_q.args[5], "%鲁%")
    Assert.eq(count_q.args[6], "%鲁%")

    -- 分类列表
    local cats = BookDB.categoriesBySource("local")
    Assert.eq(#cats, 2)
    Assert.eq(cats[1], "sub")
    local series = BookDB.seriesBySource("local")
    Assert.eq(#series, 2)
    Assert.eq(series[1], "第一辑")

    DbBase.close()
    clearMods()
end

-- ── schema migration：旧版本原地升级，未来版本拒绝且绝不清库 ──
do
    local function openWith(version)
        local execs = {}
        local connection = {
            exec = function(_, sql)
                execs[#execs + 1] = sql
            end,
            close = function() end,
            prepare = function(_, sql)
                return {
                    bind = function(self)
                        return self
                    end,
                    step = function()
                        if sql:find("user_version", 1, true) then
                            return { version }, { "user_version" }
                        end
                        return nil
                    end,
                    close = function() end,
                }
            end,
        }
        stubTask(true)
        stubDbDeps()
        package.preload["lua-ljsqlite3/init"] = function()
            return { open = function() return connection end }
        end
        package.loaded["utils.db.base"] = nil
        local DbBase = require("utils.db.base")
        local opened, open_err = DbBase.open()
        local dropped = false
        for _, sql in ipairs(execs) do
            if sql:find("DROP TABLE IF EXISTS books", 1, true) then
                dropped = true
                break
            end
        end
        DbBase.close()
        clearMods()
        local created_notes = false
        for _, sql in ipairs(execs) do
            if sql:find("CREATE TABLE IF NOT EXISTS notes", 1, true) then
                created_notes = true
                break
            end
        end
        return opened, open_err, dropped, created_notes
    end

    local opened, open_err, dropped, created_notes = openWith(1)
    Assert.not_nil(opened)
    Assert.is_nil(open_err)
    Assert.is_false(dropped)
    Assert.is_true(created_notes)
    opened, open_err, dropped, created_notes = openWith(0)
    Assert.not_nil(opened)
    Assert.is_false(dropped)
    Assert.is_true(created_notes)
    opened, open_err, dropped, created_notes = openWith(5)
    Assert.is_nil(opened)
    Assert.matches(open_err, "newer")
    Assert.is_false(dropped)
    Assert.is_false(created_notes)
end

-- ── reading_stats 聚合查询（本地洞察）──
do
    local calls = {}
    local connection = {
        exec = function() end,
        close = function() end,
        prepare = function(_, sql)
            local call = { sql = sql }
            calls[#calls + 1] = call
            return {
                bind = function(self, ...)
                    call.args = { ... }
                    return self
                end,
                step = function()
                    if sql:find("MAX(start_time)", 1, true) then
                        return { 3660, 3, 2000 }, { "s", "c", "m" }
                    end
                    if sql:find("COALESCE(SUM(duration),0), COUNT(*)", 1, true) then
                        return { 3600, 42 }, { "s", "c" }
                    end
                    if sql:find("start of day", 1, true) then
                        return { 600 }, { "s" }
                    end
                    if sql:find("MAX(day_total)", 1, true) then
                        return { 1200 }, { "s" }
                    end
                    return nil
                end,
                resultset = function()
                    if sql:find("GROUP BY day, stable_id", 1, true) then
                        return {
                            { "2026-08-15" },
                            { "/books/a.epub" },
                            { 600 },
                            { 10 },
                            { 20 },
                        }, 1
                    end
                    if sql:find("ORDER BY day DESC", 1, true) then
                        return {
                            { "2026-08-15", "2026-08-14" },
                            { 600, 300 },
                            { 10, 5 },
                        }, 2
                    end
                    return {
                        { "2026-08-14", "2026-08-15" },
                        { 300, 600 },
                        { 5, 10 },
                    }, 2
                end,
                close = function() end,
            }
        end,
    }

    stubTask(true)
    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return connection end }
    end
    package.loaded["utils.db.base"] = nil
    package.loaded["utils.db.stats"] = nil

    local DbBase = require("utils.db.base")
    local StatsDB = require("utils.db.stats")
    DbBase.open()

    local s = StatsDB.summaryBySource("local")
    Assert.eq(s.total_seconds, 3600)
    Assert.eq(s.total_pages, 42)
    Assert.eq(s.last7_seconds, 600)
    Assert.eq(s.longest_day_seconds, 1200)

    local daily = StatsDB.dailyBySource("local")
    Assert.eq(#daily, 2)
    Assert.eq(daily[1].ymd, "2026-08-14")
    Assert.eq(daily[2].seconds, 600)

    local books = StatsDB.dailyBooksBySource("local")
    Assert.eq(#books, 1)
    Assert.eq(books[1].stable_id, "/books/a.epub")
    Assert.eq(books[1].max_page, 10)
    Assert.eq(books[1].max_total_pages, 20)

    -- 按书聚合（详情页阅读情况）
    local sb = StatsDB.summaryByBook("local", "/books/a.epub")
    Assert.eq(sb.total_seconds, 3660)
    Assert.eq(sb.pages, 3)
    Assert.eq(sb.last_read, 2000)
    local sb_q = calls[#calls]
    Assert.is_true(sb_q.sql:find("AND stable_id=?", 1, true) ~= nil)
    Assert.eq(sb_q.args[1], "local")
    Assert.eq(sb_q.args[2], "/books/a.epub")

    -- 非法身份在碰 DB 前拒绝
    local empty = StatsDB.summaryByBook("", "/books/a.epub")
    Assert.eq(empty.pages, 0)
    Assert.eq(empty.last_read, 0)
    empty = StatsDB.summaryByBook("local", "")
    Assert.eq(empty.total_seconds, 0)

    -- 按书按天聚合（详情页最近几天卡片）：日期倒序 + LIMIT 绑定
    local bd = StatsDB.dailyByBook("local", "/books/a.epub", 5)
    Assert.eq(#bd, 2)
    Assert.eq(bd[1].ymd, "2026-08-15")
    Assert.eq(bd[1].seconds, 600)
    Assert.eq(bd[1].pages, 10)
    Assert.eq(bd[2].ymd, "2026-08-14")
    local bd_q = calls[#calls]
    Assert.is_true(bd_q.sql:find("AND stable_id=?", 1, true) ~= nil)
    Assert.is_true(bd_q.sql:find("LIMIT ?", 1, true) ~= nil)
    Assert.eq(bd_q.args[1], "local")
    Assert.eq(bd_q.args[2], "/books/a.epub")
    Assert.eq(bd_q.args[3], 5)
    Assert.eq(#StatsDB.dailyByBook("", "/books/a.epub"), 0)

    -- 全部参数化：source_id 绑定，不以字面量拼进 SQL
    for _, c in ipairs(calls) do
        Assert.is_false(c.sql:find("'local'", 1, true) ~= nil)
    end

    DbBase.close()
    clearMods()
end
