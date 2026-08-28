--[[--
utils.db.chapter：chapters 表 CRUD（章节文件路径 → 书籍身份，path 主键）

@module tests.utils.db.chapter_spec
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
        "utils.db.chapter",
    }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end

-- 假连接：prepare/exec 均记录；step/resultset/exec 结果由 opts 回调供给
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

local function loadChapter(connection)
    stubTask(true)
    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return connection end }
    end
    package.loaded["utils.db.base"] = nil
    package.loaded["utils.db.chapter"] = nil
    local DbBase = require("utils.db.base")
    local ChapterDB = require("utils.db.chapter")
    DbBase.open()
    return DbBase, ChapterDB
end

-- ── upsert：INSERT + ON CONFLICT(path)，5 个绑定全参数化 ──
do
    local connection, calls = makeConn()
    local DbBase, ChapterDB = loadChapter(connection)

    local path = "/cache/moon/book/x/3'); DROP TABLE chapters;--.html"
    Assert.is_true(ChapterDB.upsert({
        path = path,
        source_id = "moon",
        stable_id = "book'1",
        chapter_idx = 3,
    }))
    local q = calls[#calls]
    Assert.is_true(q.sql:find("INSERT INTO chapters", 1, true) ~= nil)
    Assert.is_true(q.sql:find("ON CONFLICT(path) DO UPDATE", 1, true) ~= nil)
    Assert.eq(q.argc, 5)
    Assert.eq(q.args[1], path)
    Assert.eq(q.args[2], "moon")
    Assert.eq(q.args[3], "book'1")
    Assert.eq(q.args[4], 3)
    Assert.eq(type(q.args[5]), "number") -- updated_at = os.time()
    Assert.is_false(q.sql:find("DROP TABLE", 1, true) ~= nil)

    -- chapter_idx 字符串数字被 tonumber
    Assert.is_true(ChapterDB.upsert({
        path = "/cache/moon/book/x/4.html",
        source_id = "moon",
        stable_id = "book1",
        chapter_idx = "4",
    }))
    Assert.eq(calls[#calls].args[4], 4)

    DbBase.close()
    clearMods()
end

-- ── get：命中返回身份表；chapter_idx 转数字；path 参数化 ──
do
    local connection, calls = makeConn({
        step = function()
            return { "moon", "book'1", "3" }, { "source_id", "stable_id", "chapter_idx" }
        end,
    })
    local DbBase, ChapterDB = loadChapter(connection)

    local row = ChapterDB.get("/cache/moon/book/x/3.html")
    Assert.not_nil(row)
    Assert.eq(row.source_id, "moon")
    Assert.eq(row.stable_id, "book'1")
    Assert.eq(row.chapter_idx, 3)
    local q = calls[#calls]
    Assert.eq(q.sql, "SELECT source_id, stable_id, chapter_idx FROM chapters WHERE path=? LIMIT 1;")
    Assert.eq(q.argc, 1)
    Assert.eq(q.args[1], "/cache/moon/book/x/3.html")
    Assert.is_false(q.sql:find("book'1", 1, true) ~= nil)

    DbBase.close()
    clearMods()
end

-- ── get：未命中 nil ──────────────────────────────────────
do
    local connection = makeConn()
    local DbBase, ChapterDB = loadChapter(connection)

    Assert.is_nil(ChapterDB.get("/cache/moon/book/x/missing.html"))

    DbBase.close()
    clearMods()
end

-- ── delete：path 绑定删除 ────────────────────────────────
do
    local connection, calls = makeConn()
    local DbBase, ChapterDB = loadChapter(connection)

    Assert.is_true(ChapterDB.delete("/cache/moon/book/x/3.html"))
    local q = calls[#calls]
    Assert.eq(q.sql, "DELETE FROM chapters WHERE path=?;")
    Assert.eq(q.argc, 1)
    Assert.eq(q.args[1], "/cache/moon/book/x/3.html")

    DbBase.close()
    clearMods()
end

-- ── deleteUnder：LIKE 前缀删目录，通配符转义 ──────────────
do
    local connection, calls = makeConn()
    local DbBase, ChapterDB = loadChapter(connection)

    Assert.is_true(ChapterDB.deleteUnder("/cache/mo%on_book"))
    local q = calls[#calls]
    Assert.is_true(q.sql:find([[DELETE FROM chapters WHERE path LIKE ? ESCAPE '\';]], 1, true) ~= nil)
    Assert.eq(q.argc, 1)
    Assert.eq(q.args[1], [[/cache/mo\%on\_book/%]]) -- % _ 转义后拼 "/%"
    Assert.is_false(q.sql:find("/cache/", 1, true) ~= nil) -- 目录不拼进 SQL

    -- 空目录名会拼成 LIKE '/%' 删光全表，必须在碰 DB 前拒绝
    local before = #calls
    Assert.is_false(ChapterDB.deleteUnder(""))
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── all：全量登记映射；空库返回 {} ───────────────────────
do
    local connection, calls = makeConn({
        exec = function(sql)
            if sql:find("FROM chapters;", 1, true) then
                return {
                    { "/cache/moon/book/x/1.html", "/cache/moon/book/x/2.html" },
                    { "moon", "moon" },
                    { "b1", "b1" },
                    { 1, 2 },
                }, 2
            end
        end,
    })
    local DbBase, ChapterDB = loadChapter(connection)

    local rows = ChapterDB.all()
    Assert.eq(#rows, 2)
    Assert.eq(rows[1].path, "/cache/moon/book/x/1.html")
    Assert.eq(rows[1].source_id, "moon")
    Assert.eq(rows[1].stable_id, "b1")
    Assert.eq(rows[1].chapter_idx, 1)
    Assert.eq(rows[2].chapter_idx, 2)

    DbBase.close()
    clearMods()
end

do
    local connection = makeConn()
    local DbBase, ChapterDB = loadChapter(connection)
    Assert.eq(#ChapterDB.all(), 0)
    DbBase.close()
    clearMods()
end

-- ── clear：全表清空 ─────────────────────────────────────
do
    local connection, calls = makeConn()
    local DbBase, ChapterDB = loadChapter(connection)

    Assert.is_true(ChapterDB.clear())
    Assert.eq(calls[#calls].sql, "DELETE FROM chapters;")

    DbBase.close()
    clearMods()
end
