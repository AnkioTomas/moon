--[[--
utils.db.book：books 表 CRUD（listBySource / 分类与系列查询已在 db_spec 覆盖）

重点：favoriteToDb 三态契约 —— nil→NULL / string→原样 / boolean→"true"/"false"；
路径登记（getByPath / touchPath / clearPath(s) / pathsAll / recentBySource / clearOpens）。

@module tests.utils.db.book_spec
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

local function loadBook(connection)
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
    return DbBase, BookDB
end

-- upsert 绑定列序：1 source_id, 2 stable_id, 3 md5, 4 title, 5 authors,
--                 6 percent, 7 category, 8 favorite, 9 series, 10 intro, 11 fetched_at, 12 path

-- ── upsert：favoriteToDb 三态契约 ────────────────────────
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    -- 态 1：nil → 绑定 nil（DB NULL）
    Assert.is_true(BookDB.upsert({ source_id = "local", stable_id = "/a.epub" }))
    local q = calls[#calls]
    Assert.is_true(q.sql:find("INSERT INTO books", 1, true) ~= nil)
    Assert.is_true(q.sql:find("ON CONFLICT(source_id, stable_id) DO UPDATE", 1, true) ~= nil)
    Assert.eq(q.argc, 12)
    Assert.eq(q.args[8], nil)

    -- 态 2：string → 原样透传
    Assert.is_true(BookDB.upsert({ source_id = "local", stable_id = "/a.epub", favorite = "置顶" }))
    Assert.eq(calls[#calls].args[8], "置顶")

    -- 态 3：boolean → tostring（"true" / "false"）
    Assert.is_true(BookDB.upsert({ source_id = "local", stable_id = "/a.epub", favorite = true }))
    Assert.eq(calls[#calls].args[8], "true")
    Assert.is_true(BookDB.upsert({ source_id = "local", stable_id = "/a.epub", favorite = false }))
    Assert.eq(calls[#calls].args[8], "false")

    DbBase.close()
    clearMods()
end

-- ── upsert：字段绑定与类型强转，全参数化 ─────────────────
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    Assert.is_true(BookDB.upsert({
        source_id = "local",
        stable_id = 12345, -- number 被 tostring
        md5 = "d41d8cd9",
        title = "书'名",
        authors = "作者",
        percent = "42.5", -- 字符串进度被 tonumber
        category = "科幻",
        series = "三部曲",
        intro = "简介\n换行",
        fetched_at = 1000,
        path = "/cache/local/book/x/book.epub",
    }))
    local q = calls[#calls]
    Assert.eq(q.argc, 12)
    Assert.eq(q.args[1], "local")
    Assert.eq(q.args[2], "12345")
    Assert.eq(q.args[3], "d41d8cd9")
    Assert.eq(q.args[4], "书'名")
    Assert.eq(q.args[6], 42.5)
    Assert.eq(q.args[7], "科幻")
    Assert.eq(q.args[9], "三部曲")
    Assert.eq(q.args[10], "简介\n换行")
    Assert.eq(q.args[11], 1000)
    Assert.eq(q.args[12], "/cache/local/book/x/book.epub")
    Assert.is_false(q.sql:find("书'名", 1, true) ~= nil)

    -- fetched_at 缺省 → os.time()；percent 缺省 → 0；path 缺省 → NULL
    Assert.is_true(BookDB.upsert({ source_id = "local", stable_id = "/b.epub" }))
    q = calls[#calls]
    Assert.eq(q.args[6], 0)
    Assert.eq(type(q.args[11]), "number")
    Assert.eq(q.args[12], nil)

    -- md5 冲突时 COALESCE 保留旧值（契约：身份摘要不覆盖）
    Assert.is_true(q.sql:find("md5=COALESCE(excluded.md5, books.md5)", 1, true) ~= nil)
    -- path 冲突时 COALESCE 保留旧值（列表回写不抹掉已登记路径）
    Assert.is_true(q.sql:find("path=COALESCE(excluded.path, books.path)", 1, true) ~= nil)

    DbBase.close()
    clearMods()
end

-- ── upsert：非法输入拒绝且不碰 DB ────────────────────────
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)
    local before = #calls

    Assert.is_false(BookDB.upsert(nil))
    Assert.is_false(BookDB.upsert("x"))
    Assert.is_false(BookDB.upsert({ stable_id = "/a.epub" })) -- 缺 source_id
    Assert.is_false(BookDB.upsert({ source_id = "", stable_id = "/a.epub" }))
    Assert.is_false(BookDB.upsert({ source_id = "local" })) -- 缺 stable_id
    Assert.is_false(BookDB.upsert({ source_id = "local", stable_id = "" }))
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── upsertRemote：普通缓存不改变书架成员；完整快照显式恢复成员 ──
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    Assert.is_true(BookDB.upsertRemote({ source_id = "moon", stable_id = "store.epub" }))
    local q = calls[#calls]
    Assert.eq(q.args[13], 0, "新缓存行默认不进入书架")
    Assert.eq(q.args[14], 0, "未指定成员关系时冲突行必须保留原值")
    Assert.is_true(q.sql:find("CASE WHEN ?=1 THEN excluded.in_library ELSE books.in_library END", 1, true) ~= nil)

    Assert.is_true(BookDB.upsertRemote({
        source_id = "moon", stable_id = "shelf.epub", in_library = true,
    }))
    q = calls[#calls]
    Assert.eq(q.args[13], 1)
    Assert.eq(q.args[14], 1)

    DbBase.close()
    clearMods()
end

-- ── reconcile：先隐藏旧成员，再恢复完整快照；任一写失败整体回滚 ──
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)
    Assert.is_true(BookDB.reconcile("moon", {
        { stable_id = "a.epub", title = "A" },
        { source_id = "moon", stable_id = "b.epub", title = "B" },
    }))
    local hide, inserts, commit = 0, 0, false
    for _, call in ipairs(calls) do
        if call.sql == "UPDATE books SET in_library=0 WHERE source_id=?;" then hide = hide + 1 end
        if call.sql:find("INSERT INTO books", 1, true) and call.argc == 14 then
            inserts = inserts + 1
            Assert.eq(call.args[13], 1)
            Assert.eq(call.args[14], 1)
        end
        if call.sql == "COMMIT;" then commit = true end
    end
    Assert.eq(hide, 1)
    Assert.eq(inserts, 2)
    Assert.is_true(commit)
    DbBase.close()
    clearMods()
end

do
    local connection, calls = makeConn({
        step = function(sql)
            if sql:find("INSERT INTO books", 1, true) then error("disk full") end
        end,
    })
    local DbBase, BookDB = loadBook(connection)
    Assert.is_false(BookDB.reconcile("moon", { { stable_id = "a.epub" } }))
    Assert.eq(calls[#calls].sql, "ROLLBACK;")
    DbBase.close()
    clearMods()
end

-- ── get：命中映射 Book；未命中 nil；非法输入不碰 DB ──────
do
    local connection, calls = makeConn({
        step = function()
            return {
                "moon", "id'1", "md5x", "标题", "作者",
                66, "分类", "true", "系列", "简介", 1000,
                "/cache/moon/book/x/book.epub", 200, 5,
            }, {
                "source_id", "stable_id", "md5", "title", "authors",
                "percent", "category", "favorite", "series", "intro", "fetched_at",
                "path", "last_open", "last_chapter_idx",
            }
        end,
    })
    local DbBase, BookDB = loadBook(connection)

    local book = BookDB.get("moon", "id'1")
    Assert.not_nil(book)
    Assert.eq(book.source_id, "moon")
    Assert.eq(book.stable_id, "id'1")
    Assert.eq(book.md5, "md5x")
    Assert.eq(book.title, "标题")
    Assert.eq(book.percent, 66)
    Assert.eq(book.favorite, "true") -- DB 原样返回，不做反序列化
    Assert.eq(book.fetched_at, 1000)
    Assert.eq(book.path, "/cache/moon/book/x/book.epub")
    Assert.eq(book.last_open, 200)
    Assert.eq(book.last_chapter_idx, 5)
    local q = calls[#calls]
    Assert.is_true(q.sql:find("FROM books WHERE source_id=? AND stable_id=? LIMIT 1;", 1, true) ~= nil)
    Assert.eq(q.argc, 2)
    Assert.eq(q.args[1], "moon")
    Assert.eq(q.args[2], "id'1")
    Assert.is_false(q.sql:find("id'1", 1, true) ~= nil)

    DbBase.close()
    clearMods()
end

-- ── get：未命中返回 nil；非法输入拒绝 ────────────────────
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    Assert.is_nil(BookDB.get("moon", "missing"))
    local before = #calls
    Assert.is_nil(BookDB.get("", "a"))
    Assert.is_nil(BookDB.get("moon", ""))
    Assert.is_nil(BookDB.get("moon", nil))
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── getByPath：物理路径精确查库；非法输入不碰 DB ──────────
do
    local connection, calls = makeConn({
        step = function()
            return {
                "moon", "b1", nil, "标题", nil,
                0, nil, nil, nil, nil, 0,
                "/cache/moon/book/x/book.epub", 300, nil,
            }, {
                "source_id", "stable_id", "md5", "title", "authors",
                "percent", "category", "favorite", "series", "intro", "fetched_at",
                "path", "last_open", "last_chapter_idx",
            }
        end,
    })
    local DbBase, BookDB = loadBook(connection)

    local book = BookDB.getByPath("/cache/moon/book/x/book.epub")
    Assert.not_nil(book)
    Assert.eq(book.source_id, "moon")
    Assert.eq(book.stable_id, "b1")
    Assert.eq(book.path, "/cache/moon/book/x/book.epub")
    Assert.eq(book.last_open, 300)
    local q = calls[#calls]
    Assert.is_true(q.sql:find("FROM books WHERE path=? LIMIT 1;", 1, true) ~= nil)
    Assert.eq(q.argc, 1)
    Assert.eq(q.args[1], "/cache/moon/book/x/book.epub")

    local before = #calls
    Assert.is_nil(BookDB.getByPath(""))
    Assert.is_nil(BookDB.getByPath(nil))
    Assert.is_nil(BookDB.getByPath(123))
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── touchPath：登记 path + last_open（+ last_chapter_idx），全参数化 ──
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    Assert.is_true(BookDB.touchPath("local", "/a.epub", "/a.epub", 3))
    local q = calls[#calls]
    Assert.is_true(q.sql:find("INSERT INTO books (source_id, stable_id, fetched_at, path, last_open, last_chapter_idx)", 1, true) ~= nil)
    Assert.is_true(q.sql:find("ON CONFLICT(source_id, stable_id) DO UPDATE", 1, true) ~= nil)
    Assert.eq(q.argc, 5)
    Assert.eq(q.args[1], "local")
    Assert.eq(q.args[2], "/a.epub")
    Assert.eq(q.args[3], "/a.epub")
    Assert.eq(type(q.args[4]), "number") -- last_open = os.time()
    Assert.eq(q.args[5], 3)

    -- chapter_idx 可空（整本书）
    Assert.is_true(BookDB.touchPath("moon", "b1", "/cache/moon/book/x/book.epub"))
    Assert.eq(calls[#calls].args[5], nil)

    -- 非法输入拒绝且不碰 DB
    local before = #calls
    Assert.is_false(BookDB.touchPath("", "/a", "/a"))
    Assert.is_false(BookDB.touchPath("local", "", "/a"))
    Assert.is_false(BookDB.touchPath("local", nil, "/a"))
    Assert.is_false(BookDB.touchPath("local", "/a", ""))
    Assert.is_false(BookDB.touchPath("local", "/a", nil))
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── clearPath：清掉指向某文件的 path 登记 ─────────────────
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    Assert.is_true(BookDB.clearPath("/cache/moon/book/x/book.epub"))
    local q = calls[#calls]
    Assert.eq(q.sql, "UPDATE books SET path=NULL, last_chapter_idx=NULL WHERE path=?;")
    Assert.eq(q.argc, 1)
    Assert.eq(q.args[1], "/cache/moon/book/x/book.epub")

    local before = #calls
    Assert.is_false(BookDB.clearPath(""))
    Assert.is_false(BookDB.clearPath(nil))
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── clearPathsUnder：LIKE 前缀清目录，通配符转义 ──────────
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    Assert.is_true(BookDB.clearPathsUnder("/cache/mo%on_book"))
    local q = calls[#calls]
    Assert.is_true(q.sql:find([[WHERE path LIKE ? ESCAPE '\';]], 1, true) ~= nil)
    Assert.eq(q.argc, 1)
    Assert.eq(q.args[1], [[/cache/mo\%on\_book/%]]) -- % _ 转义后拼 "/%"
    Assert.is_false(q.sql:find("/cache/", 1, true) ~= nil) -- 目录不拼进 SQL

    local before = #calls
    Assert.is_false(BookDB.clearPathsUnder(""))
    Assert.is_false(BookDB.clearPathsUnder(nil))
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── pathsAll：全部已登记路径；空库返回 {} ─────────────────
do
    local connection, calls = makeConn({
        exec = function(sql)
            if sql:find("FROM books WHERE path IS NOT NULL", 1, true) then
                return {
                    { "local", "moon" },
                    { "/a.epub", "b1" },
                    { "/a.epub", "/cache/moon/book/x/book.epub" },
                }, 2
            end
        end,
    })
    local DbBase, BookDB = loadBook(connection)

    local rows = BookDB.pathsAll()
    Assert.eq(#rows, 2)
    Assert.eq(rows[1].source_id, "local")
    Assert.eq(rows[1].stable_id, "/a.epub")
    Assert.eq(rows[1].path, "/a.epub")
    Assert.eq(rows[2].source_id, "moon")
    Assert.eq(rows[2].path, "/cache/moon/book/x/book.epub")

    DbBase.close()
    clearMods()
end

do
    local connection = makeConn()
    local DbBase, BookDB = loadBook(connection)
    Assert.eq(#BookDB.pathsAll(), 0)
    DbBase.close()
    clearMods()
end

-- ── recentBySource：last_open>0 倒序 + LIMIT 绑定 ─────────
do
    local connection, calls = makeConn({
        resultset = function()
            return {
                { "local", "local" },
                { "/b.epub", "/a.epub" },
                { nil, "md5a" },
                { "书名B", "书名A" },
                { "作者B", nil },
                { 10, 42 },
                { nil, "sub" },
                { nil, nil },
                { nil, nil },
                { nil, "介绍A" },
                { 0, 1000 },
                { "/b.epub", "/a.epub" },
                { 200, 100 },
                { nil, 5 },
            }, 2
        end,
    })
    local DbBase, BookDB = loadBook(connection)

    local rows = BookDB.recentBySource("local", 24)
    Assert.eq(#rows, 2)
    Assert.eq(rows[1].stable_id, "/b.epub")
    Assert.eq(rows[1].last_open, 200)
    Assert.eq(rows[1].title, "书名B")
    Assert.eq(rows[2].stable_id, "/a.epub")
    Assert.eq(rows[2].last_chapter_idx, 5)
    local q = calls[#calls]
    Assert.is_true(q.sql:find("pending_progress", 1, true) ~= nil)
    Assert.is_true(q.sql:find("COALESCE", 1, true) ~= nil)
    Assert.is_true(q.sql:find("ORDER BY b.last_open DESC", 1, true) ~= nil)
    Assert.eq(q.args[1], "local")
    Assert.eq(q.args[2], 24)

    -- limit 缺省 24
    BookDB.recentBySource("local")
    Assert.eq(calls[#calls].args[2], 24)

    -- 非法 source_id 返回 {} 且不碰 DB
    local before = #calls
    Assert.eq(#BookDB.recentBySource(""), 0)
    Assert.eq(#BookDB.recentBySource(nil), 0)
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── clearOpens：全表清打开记录与路径登记 ──────────────────
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    Assert.is_true(BookDB.clearOpens())
    Assert.eq(calls[#calls].sql, "UPDATE books SET path=NULL, last_open=0, last_chapter_idx=NULL;")

    DbBase.close()
    clearMods()
end

-- ── renameStableId：五表同步改写，全参数化 ───────────────
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    Assert.is_true(BookDB.renameStableId("local", "/old.a'epub", "/new.epub", "小说", "第一辑"))
    -- 五表更新包在事务里：BEGIN 在首个 UPDATE 之前，末条是 COMMIT
    local first_update
    for i, c in ipairs(calls) do
        if c.sql:find("UPDATE", 1, true) then
            first_update = i
            break
        end
    end
    Assert.eq(calls[first_update - 1].sql, "BEGIN IMMEDIATE;")
    Assert.eq(calls[#calls].sql, "COMMIT;")
    local updates = {}
    for _, c in ipairs(calls) do
        if c.sql:find("UPDATE", 1, true) then
            updates[#updates + 1] = c
        end
    end
    Assert.eq(#updates, 5)
    Assert.is_true(updates[1].sql:find("UPDATE books SET stable_id=?, category=?, series=?, path=?", 1, true) ~= nil)
    Assert.is_true(updates[2].sql:find("UPDATE chapters SET stable_id=?", 1, true) ~= nil)
    Assert.is_true(updates[3].sql:find("UPDATE reading_stats SET stable_id=?", 1, true) ~= nil)
    Assert.is_true(updates[4].sql:find("UPDATE notes SET stable_id=?", 1, true) ~= nil)
    Assert.is_true(updates[5].sql:find("UPDATE pending_progress SET stable_id=?", 1, true) ~= nil)
    -- books 更新带 category/series（位置派生字段随新路径刷新）+ path（本地源 path==stable_id），其余四表只改 stable_id
    Assert.eq(updates[1].argc, 6)
    Assert.eq(updates[1].args[1], "/new.epub")
    Assert.eq(updates[1].args[2], "小说")
    Assert.eq(updates[1].args[3], "第一辑")
    Assert.eq(updates[1].args[4], "/new.epub") -- path 同步改写为新 stable_id
    Assert.eq(updates[1].args[5], "local")
    Assert.eq(updates[1].args[6], "/old.a'epub")
    for i = 2, 5 do
        local u = updates[i]
        Assert.eq(u.argc, 3)
        Assert.eq(u.args[1], "/new.epub")
        Assert.eq(u.args[2], "local")
        Assert.eq(u.args[3], "/old.a'epub")
    end
    for _, u in ipairs(updates) do
        Assert.is_false(u.sql:find("/new.epub", 1, true) ~= nil)
        Assert.is_false(u.sql:find("/old.a'epub", 1, true) ~= nil)
    end

    DbBase.close()
    clearMods()
end

-- ── renameStableId：中途失败短路、整体回滚、返回 false ────
do
    local connection, calls = makeConn({
        step = function(sql)
            if sql:find("reading_stats", 1, true) then
                error("disk I/O error")
            end
        end,
    })
    local DbBase, BookDB = loadBook(connection)

    Assert.is_false(BookDB.renameStableId("local", "/old.epub", "/new.epub"))
    Assert.eq(calls[#calls].sql, "ROLLBACK;")
    -- reading_stats 炸在第三步：pending_progress 不再执行
    local updates = 0
    for _, c in ipairs(calls) do
        if c.sql:find("UPDATE", 1, true) then
            updates = updates + 1
        end
    end
    Assert.eq(updates, 3)

    DbBase.close()
    clearMods()
end

-- ── renameStableId：新旧相同直接成功不碰 DB；非法输入拒绝 ─
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)
    local before = #calls

    Assert.is_true(BookDB.renameStableId("local", "/a.epub", "/a.epub"))
    Assert.eq(#calls, before)

    Assert.is_false(BookDB.renameStableId("", "/a", "/b"))
    Assert.is_false(BookDB.renameStableId("local", "", "/b"))
    Assert.is_false(BookDB.renameStableId("local", "/a", ""))
    Assert.is_false(BookDB.renameStableId("local", nil, "/b"))
    Assert.is_false(BookDB.renameStableId("local", "/a", nil))
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── stableIdsBySource：行映射；非法输入返回 {} ───────────
do
    local connection, calls = makeConn({
        resultset = function()
            return { { "/a.epub", "/b.epub", "/c.epub" } }, 3
        end,
    })
    local DbBase, BookDB = loadBook(connection)

    local ids = BookDB.stableIdsBySource("local")
    Assert.eq(#ids, 3)
    Assert.eq(ids[1], "/a.epub")
    Assert.eq(ids[3], "/c.epub")
    local q = calls[#calls]
    Assert.eq(q.sql, "SELECT stable_id FROM books WHERE source_id=?;")
    Assert.eq(q.args[1], "local")

    local before = #calls
    Assert.eq(#BookDB.stableIdsBySource(""), 0)
    Assert.eq(#BookDB.stableIdsBySource(nil), 0)
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── remove：双键绑定删除；非法输入拒绝 ───────────────────
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    Assert.is_true(BookDB.remove("local", "/a'); DROP TABLE books;--"))
    local q = calls[#calls]
    Assert.eq(q.sql, "DELETE FROM books WHERE source_id=? AND stable_id=?;")
    Assert.eq(q.argc, 2)
    Assert.eq(q.args[1], "local")
    Assert.eq(q.args[2], "/a'); DROP TABLE books;--")
    Assert.is_false(q.sql:find("DROP TABLE", 1, true) ~= nil)

    local before = #calls
    Assert.is_false(BookDB.remove("", "/a"))
    Assert.is_false(BookDB.remove("local", ""))
    Assert.is_false(BookDB.remove("local", nil))
    Assert.eq(#calls, before)

    DbBase.close()
    clearMods()
end

-- ── stripMeta：无 WHERE 全表清元数据（保留键与 md5）──────
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    Assert.is_true(BookDB.stripMeta())
    local q = calls[#calls]
    Assert.is_true(q.sql:find("UPDATE books SET", 1, true) ~= nil)
    Assert.is_false(q.sql:find("WHERE", 1, true) ~= nil)
    Assert.is_true(q.sql:find("title=NULL", 1, true) ~= nil)
    Assert.is_true(q.sql:find("favorite=NULL", 1, true) ~= nil)
    Assert.is_true(q.sql:find("fetched_at=0", 1, true) ~= nil)
    Assert.is_false(q.sql:find("md5=NULL", 1, true) ~= nil) -- md5 必须保留
    Assert.eq(q.argc, 0)

    DbBase.close()
    clearMods()
end

-- ── expireBefore：WHERE 绑定时间戳；非数字按 0 处理 ──────
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    Assert.is_true(BookDB.expireBefore(1700000000))
    local q = calls[#calls]
    Assert.is_true(q.sql:find("UPDATE books SET", 1, true) ~= nil)
    Assert.is_true(q.sql:find("WHERE fetched_at > 0 AND fetched_at < ?;", 1, true) ~= nil)
    Assert.eq(q.argc, 1)
    Assert.eq(q.args[1], 1700000000)
    Assert.is_false(q.sql:find("1700000000", 1, true) ~= nil)

    Assert.is_true(BookDB.expireBefore("not-a-number"))
    Assert.eq(calls[#calls].args[1], 0)

    DbBase.close()
    clearMods()
end

-- ── remove：连带清目录缓存（toc.delete），非法参数不连带 ──
do
    local toc_deleted = {}
    package.preload["utils.db.toc"] = function()
        return {
            delete = function(source_id, stable_id)
                toc_deleted[#toc_deleted + 1] = { source_id = source_id, stable_id = stable_id }
                return true
            end,
        }
    end
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    Assert.is_true(BookDB.remove("moon", "b'1"))
    Assert.eq(#toc_deleted, 1)
    Assert.eq(toc_deleted[1].source_id, "moon")
    Assert.eq(toc_deleted[1].stable_id, "b'1")
    -- 连带清缓存不挡主删除：books 的 DELETE 照常执行
    Assert.eq(calls[#calls].sql, "DELETE FROM books WHERE source_id=? AND stable_id=?;")

    -- 参数校验在连带删除之前：非法输入不触 toc.delete
    Assert.is_false(BookDB.remove("", "b1"))
    Assert.is_false(BookDB.remove("moon", ""))
    Assert.eq(#toc_deleted, 1)

    DbBase.close()
    clearMods()
end
