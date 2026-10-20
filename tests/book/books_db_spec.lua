--[[--
book.books_db：books 表 CRUD（分类与系列查询见 db_spec，书库列表见 catalog_list_spec）

重点：路径登记（getByPath / touchPath / clearPathsUnder）、跨表联动只经事件。

@module tests.book.books_db_spec
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
    package.preload["utils.log"] = function()
        return { dbg = function() end, warn = function() end }
    end
    package.loaded["utils.log"] = nil
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
        "features.xray.db", "features.xray.events",
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

---@param dependents boolean|nil 扫描真实 features 目录登记数据事件订阅方（xray 迁身份）
local function loadBook(connection, dependents)
    stubTask(true)
    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return connection end }
    end
    package.preload["json"] = function() return require("support.json_stub") end
    package.loaded["json"] = nil
    package.loaded["utils.db"] = nil
    package.loaded["utils.event"] = nil
    package.loaded["book.books_db"] = nil
    local DbBase = require("utils.db")
    local BookDB = require("book.books_db")
    if dependents then
        require("utils.event").init(require("features").listeners("events"))
    end
    DbBase.open()
    return DbBase, BookDB
end

-- 旧库没有 cover 列时原地迁移；已有列不得重复 ALTER。
do
    local connection, calls = makeConn({
        exec = function(sql)
            if sql == "PRAGMA table_info(books);" then
                return { { 0, 1 }, { "source_id", "stable_id" } }, 2
            end
        end,
    })
    local DbBase = loadBook(connection)
    local alters = {}
    for _, call in ipairs(calls) do
        local name = call.sql:match("^ALTER TABLE books ADD COLUMN ([%w_]+)")
        if name then alters[name] = true end
    end
    for _, name in ipairs({
        "cover", "inserted_at", "deleted", "sync_status",
        "reader_prefs", "toc", "toc_fetched_at", "read_state",
    }) do
        Assert.is_true(alters[name], "旧库必须补列: " .. name)
    end
    DbBase.close()
    clearMods()
end

do
    local connection, calls = makeConn({
        exec = function(sql)
            if sql == "PRAGMA table_info(books);" then
                return { { 0, 1 }, { "source_id", "cover" } }, 2
            end
        end,
    })
    local DbBase = loadBook(connection)
    for _, call in ipairs(calls) do
        Assert.is_false(call.sql == "ALTER TABLE books ADD COLUMN cover TEXT;")
    end
    DbBase.close()
    clearMods()
end

-- upsert 绑定列序：1 source_id, 2 stable_id, 3 md5, 4 title, 5 authors,
--                 6 category, 7 series, 8 intro, 9 cover, 10 inserted_at, 11 path
--                 deleted/sync_status 字面 0（在架 + 脏）

-- ── upsert：字段绑定 ────────────────────────────────────
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    -- 态 1：nil → 绑定 nil（DB NULL）
    Assert.is_true(BookDB.upsert({ source_id = "local", stable_id = "/a.epub" }))
    local q = calls[#calls]
    Assert.is_true(q.sql:find("INSERT INTO books", 1, true) ~= nil)
    Assert.is_true(q.sql:find("ON CONFLICT(source_id, stable_id) DO UPDATE", 1, true) ~= nil)
    Assert.eq(q.argc, 11)
    Assert.is_true(q.sql:find("VALUES (?,?,?,?,?,?,?,?,?,?,?,0,0)", 1, true) ~= nil)
    Assert.is_true(q.sql:find("deleted=0", 1, true) ~= nil)
    Assert.is_true(q.sql:find("sync_status=0", 1, true) ~= nil)

    DbBase.close()
    clearMods()
end

-- ── upsert：字段绑定与类型强转，全参数化 ─────────────────
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    Assert.is_true(BookDB.upsert({
        source_id = "local",
        stable_id = 12345,
        md5 = "d41d8cd9",
        title = "书'名",
        authors = "作者",
        category = "科幻",
        series = "三部曲",
        intro = "简介\n换行",
        cover = "https://img.test/cover.jpg",
        inserted_at = 1000,
        path = "/cache/local/book/x/book.epub",
    }))
    local q = calls[#calls]
    Assert.eq(q.argc, 11)
    Assert.eq(q.args[1], "local")
    Assert.eq(q.args[2], 12345)
    Assert.eq(q.args[3], "d41d8cd9")
    Assert.eq(q.args[4], "书'名")
    Assert.eq(q.args[5], "作者")
    Assert.eq(q.args[6], "科幻")
    Assert.eq(q.args[7], "三部曲")
    Assert.eq(q.args[8], "简介\n换行")
    Assert.eq(q.args[9], "https://img.test/cover.jpg")
    Assert.eq(q.args[10], 1000)
    Assert.eq(q.args[11], "/cache/local/book/x/book.epub")
    Assert.is_false(q.sql:find("书'名", 1, true) ~= nil)

    -- inserted_at 缺省 → os.time()；path 缺省 → NULL
    Assert.is_true(BookDB.upsert({ source_id = "local", stable_id = "/b.epub" }))
    q = calls[#calls]
    Assert.eq(type(q.args[10]), "number")
    Assert.eq(q.args[11], nil)

    -- md5 冲突时 COALESCE 保留旧值（契约：身份摘要不覆盖）
    Assert.is_true(q.sql:find("md5=COALESCE(excluded.md5, books.md5)", 1, true) ~= nil)
    -- path 冲突时 COALESCE 保留旧值（列表回写不抹掉已登记路径）
    Assert.is_true(q.sql:find("path=COALESCE(excluded.path, books.path)", 1, true) ~= nil)

    DbBase.close()
    clearMods()
end

-- ── markSyncedMany：单事务逐行清脏 ───────────────────────
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)
    local before = #calls
    Assert.is_true(BookDB.markSyncedMany("local", { "/a.epub", "/b.epub" }))
    Assert.eq(calls[before + 1].sql, "BEGIN IMMEDIATE;")
    Assert.is_true(calls[before + 2].sql:find("UPDATE books SET sync_status=1", 1, true) ~= nil)
    Assert.eq(calls[before + 2].args[2], "/a.epub")
    Assert.eq(calls[before + 3].args[2], "/b.epub")
    Assert.eq(calls[#calls].sql, "COMMIT;")
    DbBase.close()
    clearMods()
end

-- ── upsertRemote：无 membership 默认 deleted=1；有 deleted 时写成员 ──
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    Assert.is_true(BookDB.upsertRemote({ source_id = "moon", stable_id = "store.epub" }))
    local q = calls[#calls]
    -- VALUES 13 绑定（含 read_at）+ sync_status 字面 1；UPDATE 三个 ?=1（权威加入时间 + 两个成员标志）→ argc=16
    local qmarks = select(2, q.sql:gsub("%?", "%?"))
    Assert.eq(qmarks, 16)
    Assert.eq(q.argc, 16)
    Assert.eq(q.args[12], 1, "无 membership 时 deleted 默认 1")
    Assert.eq(q.args[13], 0, "没给云端阅读时间写 0")
    Assert.eq(q.args[14], 0, "未声明权威加入时间时不得覆盖 inserted_at")
    Assert.eq(q.args[15], 0, "未指定成员关系时不得改 deleted")
    Assert.eq(q.args[16], 0, "未指定成员关系时不得改 sync_status")
    Assert.is_true(q.sql:find("VALUES (?,?,?,?,?,?,?,?,?,?,?,?,1,?)", 1, true) ~= nil)
    Assert.is_true(q.sql:find("WHEN books.sync_status=0", 1, true) ~= nil,
        "脏行保留展示字段与成员")
    Assert.is_true(q.sql:find("THEN books.title", 1, true) ~= nil)
    Assert.is_true(q.sql:find("cover=COALESCE(NULLIF(excluded.cover, ''), books.cover)", 1, true) ~= nil,
        "稀疏远端行不得清空已有封面地址")

    Assert.is_true(BookDB.upsertRemote({
        source_id = "moon", stable_id = "shelf.epub", deleted = 0,
    }))
    q = calls[#calls]
    Assert.eq(q.args[12], 0, "deleted=0 → 在架")
    Assert.eq(q.args[15], 1)
    Assert.eq(q.args[16], 1)

    Assert.is_true(BookDB.upsertRemote({
        source_id = "moon", stable_id = "gone.epub", deleted = 1,
    }))
    q = calls[#calls]
    Assert.eq(q.args[12], 1)
    Assert.eq(q.args[15], 1)

    DbBase.close()
    clearMods()
end

-- ── setMeta：入库前规范化；补缺 / 覆盖按键合并，从不清键 ──
do
    local Json = require("support.json_stub")
    local stored = nil
    local connection, calls = makeConn({
        step = function(sql)
            if sql:find("^SELECT meta FROM books") then return stored and { stored } or nil end
        end,
    })
    local DbBase, BookDB = loadBook(connection)
    local function written()
        local q = calls[#calls]
        Assert.eq(q.sql, "UPDATE books SET meta=? WHERE source_id=? AND stable_id=?;")
        return Json.decode(q.args[1])
    end

    local before = #calls
    Assert.is_true(BookDB.upsertRemote({
        source_id = "wechat", stable_id = "w1", meta = {
            publisher = "  某出版社 ", published = "2022-01-01 00:00:00", isbn = "978-7-5404-9876-5",
            language = "zh-Hans", words = "1200.7", rating = { score = 9.55, by = "weread" },
        },
    }))
    Assert.eq(#calls, before + 3, "upsert 之后读一次 meta 再写一次")
    local m = written()
    Assert.eq(m.publisher, "某出版社")
    Assert.eq(m.published, "2022-01", "日期只留年月")
    Assert.eq(m.isbn, "9787540498765", "ISBN 去掉连字符")
    Assert.eq(m.language, "zh", "语言只留主码小写")
    Assert.eq(m.words, 1200)
    Assert.eq(m.rating.score, 9.6, "10 分制一位小数，9.55 不能被浮点误差舍成 9.5")
    Assert.eq(m.rating.by, "weread")

    -- 未知值（空串 / 0 / 年份 0 / 位数不对的 ISBN / 超范围评分）丢掉；全是未知不发 SQL
    before = #calls
    Assert.is_true(BookDB.upsertRemote({
        source_id = "kavita", stable_id = "k1", meta = {
            publisher = "", published = 0, isbn = "123", language = "", words = 0, rating = { score = 0 },
        },
    }))
    Assert.eq(#calls, before + 1, "没有有效元数据只有 upsert 本身")

    Assert.eq(BookDB.upsertRemote({ source_id = "x", stable_id = "y", meta = { published = 2020 } }) and written().published,
        "2020", "数字年份")
    Assert.eq(BookDB.upsertRemote({ source_id = "x", stable_id = "y", meta = { published = "2020-5" } }) and written().published,
        "2020-05")
    Assert.eq(BookDB.upsertRemote({ source_id = "x", stable_id = "y", meta = { isbn = "0-306-40615-x" } }) and written().isbn,
        "030640615X")

    -- 普通同步只补缺的键；强制刷新覆盖传入的键；都不清掉没传的键
    stored = Json.encode({ publisher = "旧社", words = 100, detail_at = 5 })
    BookDB.upsertRemote({ source_id = "w", stable_id = "1", meta = { publisher = "新社", isbn = "9787540498765" } })
    m = written()
    Assert.eq(m.publisher, "旧社", "普通同步不覆盖已有键")
    Assert.eq(m.isbn, "9787540498765", "普通同步补缺")
    Assert.eq(m.words, 100)
    BookDB.upsertRemote({ source_id = "w", stable_id = "1", meta = { publisher = "新社" } }, true)
    m = written()
    Assert.eq(m.publisher, "新社", "强制刷新覆盖")
    Assert.eq(m.words, 100, "强制刷新不清没传的键")
    Assert.eq(m.detail_at, 5)
    BookDB.upsertLocal({ source_id = "w", stable_id = "1", title = "t", meta = { publisher = "刮削社" } })
    Assert.eq(written().publisher, "刮削社", "本地写入覆盖")

    DbBase.close()
    clearMods()
end

-- ── reconcile force 传到 upsertRemote：快照 meta 覆盖 ──
do
    local Json = require("support.json_stub")
    local connection, calls = makeConn({
        step = function(sql)
            if sql:find("^SELECT meta FROM books") then return { Json.encode({ words = 1 }) } end
        end,
    })
    local DbBase, BookDB = loadBook(connection)
    local function lastWords()
        for i = #calls, 1, -1 do
            if calls[i].sql:find("^UPDATE books SET meta") then return Json.decode(calls[i].args[1]).words end
        end
    end
    BookDB.reconcile("w", { { stable_id = "1", meta = { words = 2 } } })
    Assert.is_nil(lastWords(), "普通对账只补缺：键已在、没变，不写")
    BookDB.reconcile("w", { { stable_id = "1", meta = { words = 2 } } }, { force = true })
    Assert.eq(lastWords(), 2, "强制刷新覆盖")

    DbBase.close()
    clearMods()
end

-- ── upsertRemoteMany：逐条 upsertRemote（不再批量 VALUES）──
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)
    local before = #calls

    Assert.is_true(BookDB.upsertRemoteMany({
        { source_id = "moon", stable_id = "cache.epub" },
        { source_id = "moon", stable_id = "hidden.epub", deleted = 1 },
    }))
    local inserts = {}
    for i = before + 1, #calls do
        if calls[i].sql:find("INSERT INTO books", 1, true) then
            inserts[#inserts + 1] = calls[i]
        end
    end
    Assert.eq(#inserts, 2)
    Assert.eq(inserts[1].argc, 16)
    Assert.eq(inserts[1].args[12], 1)
    Assert.eq(inserts[1].args[15], 0)
    Assert.eq(inserts[2].argc, 16)
    Assert.eq(inserts[2].args[12], 1, "deleted=1")
    Assert.eq(inserts[2].args[15], 1)

    DbBase.close()
    clearMods()
end

-- ── reconcile：先软删已同步在架行，再逐条 upsertRemote(deleted=0) ──
do
    local connection, calls = makeConn({
        resultset = function(sql)
            if sql:find("SELECT stable_id FROM books", 1, true) then
                return { { "a.epub", "gone.epub", "old.epub" } }, 3
            end
            return nil, 0
        end,
    })
    local DbBase, BookDB = loadBook(connection)
    local ok, hidden = BookDB.reconcile("moon", {
        { stable_id = "a.epub", title = "A" },
        { source_id = "moon", stable_id = "b.epub", title = "B" },
    })
    Assert.is_true(ok)
    Assert.eq(hidden, 2, "原在架、快照缺席的行计入 hidden")
    local deactivate, inserts, commit = 0, 0, false
    local insert_calls = {}
    for _, call in ipairs(calls) do
        if call.sql:find("UPDATE books SET deleted=1", 1, true)
            and call.sql:find("deleted=0 AND sync_status=1", 1, true) then
            deactivate = deactivate + 1
        end
        if call.sql:find("INSERT INTO books", 1, true) then
            inserts = inserts + 1
            insert_calls[#insert_calls + 1] = call
            Assert.eq(call.argc, 16)
            Assert.eq(call.args[12], 0, "对账入架 deleted=0")
            Assert.eq(call.args[14], 0, "未声明权威加入时间")
            Assert.eq(call.args[15], 1)
        end
        if call.sql == "COMMIT;" then commit = true end
    end
    Assert.eq(deactivate, 1)
    Assert.eq(inserts, 2)
    Assert.eq(insert_calls[1].args[1], "moon")
    Assert.is_nil(insert_calls[1].args[3])
    Assert.eq(insert_calls[1].args[4], "A")
    Assert.eq(insert_calls[2].args[1], "moon")
    Assert.eq(insert_calls[2].args[4], "B")
    Assert.is_true(commit)
    DbBase.close()
    clearMods()
end

-- ── reconcile 空快照：自动同步不下架；allow_empty（手动刷新 / 本地扫盘）照常下架 ──
do
    local connection, calls = makeConn({ resultset = function() return { {} }, 0 end })
    local DbBase, BookDB = loadBook(connection)
    local function deactivated()
        for _, call in ipairs(calls) do
            if call.sql:find("UPDATE books SET deleted=1", 1, true) then return true end
        end
        return false
    end
    local ok, hidden = BookDB.reconcile("moon", {})
    Assert.is_true(ok)
    Assert.eq(hidden, 0)
    Assert.is_false(deactivated(), "自动同步拿到空书架不下架")
    Assert.is_true(BookDB.reconcile("moon", {}, { allow_empty = true }))
    Assert.is_true(deactivated(), "手动刷新认空快照")
    DbBase.close()
    clearMods()
end

-- ── markDeleted / pendingDeleteIds：本地软删入脏队列 ──
do
    local connection, calls = makeConn({
        resultset = function(sql)
            if sql:find("deleted=1 AND sync_status=0", 1, true) then
                return { { "del1", "del2" } }, 2
            end
            return nil, 0
        end,
    })
    local DbBase, BookDB = loadBook(connection)
    Assert.is_true(BookDB.markDeleted("wechat", "del1"))
    local q
    for i = #calls, 1, -1 do
        if calls[i].sql:find("UPDATE books SET deleted=1", 1, true) then
            q = calls[i]
            break
        end
    end
    Assert.not_nil(q)
    Assert.is_true(q.sql:find("sync_status=0", 1, true) ~= nil)
    Assert.is_true(q.sql:find("path=NULL", 1, true) ~= nil)
    Assert.eq(q.args[1], "wechat")
    Assert.eq(q.args[2], "del1")

    local pending = BookDB.pendingDeleteIds("wechat")
    Assert.eq(#pending, 2)
    Assert.eq(pending[1], "del1")
    Assert.eq(pending[2], "del2")

    DbBase.close()
    clearMods()
end

-- ── stableIdsByMd5：同内容副本全部列出（不 LIMIT 1），墓碑不算，顺序稳定 ──
do
    local connection, calls = makeConn({
        resultset = function(sql)
            if sql:find("md5=?", 1, true) then
                return { { "/books/a.epub", "/books/b.epub" } }, 2
            end
            return nil, 0
        end,
    })
    local DbBase, BookDB = loadBook(connection)
    local ids = BookDB.stableIdsByMd5("local", "m")
    Assert.eq(#ids, 2)
    Assert.eq(ids[1], "/books/a.epub")
    Assert.eq(ids[2], "/books/b.epub")
    local q = calls[#calls]
    Assert.is_true(q.sql:find("deleted=0", 1, true) ~= nil, "墓碑不能被同内容新文件收编")
    Assert.is_true(q.sql:find("ORDER BY inserted_at ASC, stable_id ASC", 1, true) ~= nil)
    Assert.is_nil(q.sql:find("LIMIT", 1, true))
    Assert.eq(q.args[1], "local")
    Assert.eq(q.args[2], "m")
    DbBase.close()
    clearMods()
end

-- ── pendingShelfAddIds：脏加架队列 ──
do
    local connection, calls = makeConn({
        resultset = function(sql)
            if sql:find("deleted=0 AND sync_status=0", 1, true) then
                return { { "add1", "add2" } }, 2
            end
            return nil, 0
        end,
    })
    local DbBase, BookDB = loadBook(connection)
    local pending = BookDB.pendingShelfAddIds("wechat")
    Assert.eq(#pending, 2)
    Assert.eq(pending[1], "add1")
    Assert.eq(pending[2], "add2")
    local q = calls[#calls]
    Assert.is_true(q.sql:find("deleted=0 AND sync_status=0", 1, true) ~= nil)

    DbBase.close()
    clearMods()
end

-- 大书架也是逐条 upsertRemote。
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)
    local books = {}
    for i = 1, 9 do
        books[i] = { stable_id = "book-" .. i, title = "Book " .. i }
    end
    Assert.is_true(BookDB.reconcile("moon", books))
    local inserts = 0
    for _, call in ipairs(calls) do
        if call.sql:find("INSERT INTO books", 1, true) then
            inserts = inserts + 1
            Assert.eq(call.argc, 16)
        end
    end
    Assert.eq(inserts, 9)
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
                "分类", "系列", "简介", "https://img.test/cover.jpg", 1000,
                "/cache/moon/book/x/book.epub", 0, 1, 1,
            }, {
                "source_id", "stable_id", "md5", "title", "authors",
                "category", "series", "intro", "cover", "inserted_at",
                "path", "deleted", "sync_status", "read_state",
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
    Assert.eq(book.percent, 0, "进度不在 books 表，percent 恒为 0")
    Assert.eq(book.cover, "https://img.test/cover.jpg")
    Assert.eq(book.inserted_at, 1000)
    Assert.eq(book.path, "/cache/moon/book/x/book.epub")
    Assert.eq(book.deleted, 0)
    Assert.eq(book.sync_status, 1)
    Assert.eq(book.read_state, 1)
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

    DbBase.close()
    clearMods()
end

-- ── getByPath：物理路径精确查库；非法输入不碰 DB ──────────
do
    local connection, calls = makeConn({
        step = function()
            return {
                "moon", "b1", nil, "标题", nil,
                nil, nil, nil, nil, 0,
                "/cache/moon/book/x/book.epub", 1, 1, 0,
            }, {
                "source_id", "stable_id", "md5", "title", "authors",
                "category", "series", "intro", "cover", "inserted_at",
                "path", "deleted", "sync_status", "read_state",
            }
        end,
    })
    local DbBase, BookDB = loadBook(connection)

    local book = BookDB.getByPath("/cache/moon/book/x/book.epub")
    Assert.not_nil(book)
    Assert.eq(book.source_id, "moon")
    Assert.eq(book.stable_id, "b1")
    Assert.eq(book.path, "/cache/moon/book/x/book.epub")
    Assert.eq(book.deleted, 1)
    local q = calls[#calls]
    Assert.is_true(q.sql:find("FROM books WHERE path=? LIMIT 1;", 1, true) ~= nil)
    Assert.eq(q.argc, 1)
    Assert.eq(q.args[1], "/cache/moon/book/x/book.epub")

    DbBase.close()
    clearMods()
end

-- ── touchPath：只登记 path，不制造书架成员 ────────────────
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    Assert.is_true(BookDB.touchPath("local", "/a.epub", "/a.epub"))
    local q = calls[#calls]
    Assert.is_true(q.sql:find(
        "INSERT INTO books (source_id, stable_id, inserted_at, path, deleted, sync_status)",
        1, true) ~= nil)
    Assert.is_true(q.sql:find("VALUES (?,?,0,?,1,1)", 1, true) ~= nil,
        "身份行必须 deleted=1, sync_status=1, inserted_at=0")
    Assert.is_true(q.sql:find("ON CONFLICT(source_id, stable_id) DO UPDATE", 1, true) ~= nil)
    Assert.eq(q.argc, 3)
    Assert.eq(q.args[1], "local")
    Assert.eq(q.args[2], "/a.epub")
    Assert.eq(q.args[3], "/a.epub")
    Assert.is_true(q.sql:find("last_open", 1, true) == nil)
    -- 第二次登记仍只覆盖路径
    Assert.is_true(BookDB.touchPath("moon", "b1", "/cache/moon/book/x/book.epub"))

    DbBase.close()
    clearMods()
end

-- ── 阅读状态：手动已读同一事务调 ProgressDB.markFinished；手动未读独立编码，自动规则不得覆盖 ──
do
    local connection, calls = makeConn()
    local marked = {}
    package.preload["book.progress_db"] = function()
        return { markFinished = function(source_id, stable_id)
            marked[#marked + 1] = { source_id, stable_id }
            return true
        end }
    end
    for _idx, name in ipairs({ "book.note_db", "book.stats_db", "features.xray.db" }) do
        package.preload[name] = function() return {} end
    end
    local DbBase, BookDB = loadBook(connection)

    Assert.is_true(BookDB.setRead("moon", "b1", true))
    Assert.eq(calls[#calls].sql, "COMMIT;", "已读与补进度同一事务")
    Assert.is_true(calls[#calls - 1].sql:find("SET read_state=1", 1, true) ~= nil)
    Assert.is_true(calls[#calls - 1].sql:find("percent", 1, true) == nil,
        "已读只改 read_state，不写 books.percent")
    for _idx, call in ipairs(calls) do
        Assert.is_nil(call.sql:find("pending_progress", 1, true), "books_db 不直接写进度表")
    end
    Assert.eq(#marked, 1)
    Assert.eq(marked[1][1], "moon")
    Assert.eq(marked[1][2], "b1")
    Assert.is_true(BookDB.setRead("moon", "b1", false))
    Assert.eq(#marked, 1, "标记未读不补进度")
    Assert.is_true(calls[#calls].sql:find("read_state=2", 1, true) ~= nil)
    Assert.eq(calls[#calls].args[1], "moon")
    Assert.is_true(calls[#calls].sql:find("percent", 1, true) == nil,
        "标记未读不得回退进度")
    Assert.is_true(BookDB.markReadAutomatically("moon", "b1"))
    Assert.is_true(calls[#calls].sql:find("AND read_state=0", 1, true) ~= nil)
    Assert.is_true(BookDB.markReadComplete("moon", "b1"))
    Assert.is_true(calls[#calls].sql:find("read_state=0", 1, true) == nil,
        "100% 完成不得受手动未读保护")

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

-- ── renameStableId：books 自己改，核心依附表按 IDENTITY_MODULES 顺序、feature 表经事件改写，全参数化 ──
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection, true)

    Assert.is_true(BookDB.renameStableId("local", "/old.a'epub", "/new.epub", "小说", "第一辑"))
    -- 身份更新包在事务里：BEGIN 在首个 UPDATE 之前，末条是 COMMIT
    local first_update
    for i, c in ipairs(calls) do
        if c.sql:find("UPDATE books SET stable_id=", 1, true) then
            first_update = i
            break
        end
    end
    Assert.eq(calls[first_update - 1].sql, "BEGIN IMMEDIATE;")
    Assert.eq(calls[#calls].sql, "COMMIT;")
    local updates = {}
    for i = first_update, #calls do
        local c = calls[i]
        if c.sql:find("UPDATE", 1, true) then
            updates[#updates + 1] = c
        end
    end
    Assert.eq(#updates, 9)
    Assert.is_true(updates[1].sql:find("UPDATE books SET stable_id=?, category=?, series=?, path=?", 1, true) ~= nil)
    -- 核心表按 IDENTITY_MODULES 顺序，最后是事件订阅方 xray
    Assert.is_true(updates[2].sql:find("UPDATE chapters SET stable_id=?", 1, true) ~= nil)
    Assert.is_true(updates[3].sql:find("UPDATE notes SET stable_id=?", 1, true) ~= nil)
    Assert.is_true(updates[4].sql:find("UPDATE pending_progress SET stable_id=?", 1, true) ~= nil)
    Assert.is_true(updates[5].sql:find("UPDATE reading_stats SET stable_id=?", 1, true) ~= nil)
    Assert.is_true(updates[6].sql:find("UPDATE review_cache SET stable_id=?", 1, true) ~= nil)
    Assert.is_true(updates[7].sql:find("UPDATE chapter_summaries SET stable_id=?", 1, true) ~= nil)
    Assert.is_true(updates[8].sql:find("UPDATE xray_entities SET stable_id=?", 1, true) ~= nil)
    Assert.is_true(updates[9].sql:find("UPDATE xray_scan SET stable_id=?", 1, true) ~= nil)
    -- books 更新带 category/series（位置派生字段随新路径刷新）+ path（本地源 path==stable_id），其余表只改 stable_id
    Assert.eq(updates[1].argc, 6)
    Assert.eq(updates[1].args[1], "/new.epub")
    Assert.eq(updates[1].args[2], "小说")
    Assert.eq(updates[1].args[3], "第一辑")
    Assert.eq(updates[1].args[4], "/new.epub") -- path 同步改写为新 stable_id
    Assert.eq(updates[1].args[5], "local")
    Assert.eq(updates[1].args[6], "/old.a'epub")
    for i = 2, 7 do
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
    local DbBase, BookDB = loadBook(connection, true)

    Assert.is_false(BookDB.renameStableId("local", "/old.epub", "/new.epub"))
    Assert.eq(calls[#calls].sql, "ROLLBACK;")
    -- reading_stats 炸在第五步（books/chapters/notes/pending_progress 之后）：xray_entities 不再执行
    local updates = 0
    local begin
    for i, c in ipairs(calls) do
        if c.sql == "BEGIN IMMEDIATE;" then begin = i end
    end
    for i = begin or 1, #calls do
        local c = calls[i]
        if c.sql:find("UPDATE", 1, true) then
            updates = updates + 1
        end
    end
    Assert.eq(updates, 5)

    DbBase.close()
    clearMods()
end

-- ── renameStableId：COMMIT 失败不得谎报成功 ───────────────
do
    local commits = 0
    local connection, calls = makeConn({
        exec = function(sql)
            if sql == "COMMIT;" then
                commits = commits + 1
                if commits == 2 then error("commit failed") end
            end
        end,
    })
    local DbBase, BookDB = loadBook(connection)

    Assert.is_false(BookDB.renameStableId("local", "/old.epub", "/new.epub"))
    Assert.eq(calls[#calls].sql, "ROLLBACK;")

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

    DbBase.close()
    clearMods()
end

-- ── remove：只撕墓碑（deleted=1），双键绑定；非法输入不拼进 SQL ──
do
    local connection, calls = makeConn()
    local DbBase, BookDB = loadBook(connection)

    Assert.is_true(BookDB.remove("local", "/a'); DROP TABLE books;--"))
    local q
    for _, call in ipairs(calls) do
        if call.sql:find("^DELETE FROM books") then q = call end
    end
    Assert.eq(q.sql, "DELETE FROM books WHERE source_id=? AND stable_id=? AND deleted=1;")
    Assert.eq(q.argc, 2)
    Assert.eq(q.args[1], "local")
    Assert.eq(q.args[2], "/a'); DROP TABLE books;--")
    Assert.is_false(q.sql:find("DROP TABLE", 1, true) ~= nil)
    Assert.eq(calls[#calls].sql, "COMMIT;")

    DbBase.close()
    clearMods()
end

-- ── remove：没撕到墓碑（不存在 / 未标删）不碰依附表 ──
do
    local connection, calls = makeConn({
        step = function(sql) if sql == "SELECT changes();" then return { 0 } end end,
    })
    local DbBase, BookDB = loadBook(connection, true)

    Assert.is_true(BookDB.remove("moon", "live"))
    for _, call in ipairs(calls) do
        Assert.is_false(call.sql:find("DELETE FROM", 1, true) ~= nil and not call.sql:find("^DELETE FROM books"),
            "未撕墓碑不应级联: " .. call.sql)
    end

    DbBase.close()
    clearMods()
end

-- ── remove：撕掉墓碑后同一事务级联清依附表（含 feature 的 xray） ──
do
    local connection, calls = makeConn({
        step = function(sql) if sql == "SELECT changes();" then return { 1 } end end,
    })
    local DbBase, BookDB = loadBook(connection, true)

    Assert.is_true(BookDB.remove("moon", "b'1"))
    local deleted = {}
    for _, call in ipairs(calls) do
        local tbl = call.sql:match("^DELETE FROM ([%w_]+) WHERE source_id=%? AND stable_id=%?;$")
        if tbl then
            deleted[tbl] = true
            Assert.eq(call.args[1], "moon")
            Assert.eq(call.args[2], "b'1")
        end
    end
    for _, tbl in ipairs({ "chapters", "notes", "pending_progress", "reading_stats", "xray_entities" }) do
        Assert.is_true(deleted[tbl], "删书须清依附表: " .. tbl)
    end
    Assert.eq(calls[#calls].sql, "COMMIT;")

    DbBase.close()
    clearMods()
end

-- ── Base.transaction：真值提交、假值回滚、抛错先回滚再原样抛出 ──
do
    local connection, calls = makeConn()
    local DbBase = loadBook(connection)
    local function last() return calls[#calls].sql end

    Assert.eq(DbBase.transaction(function() return 7 end), 7)
    Assert.eq(last(), "COMMIT;")
    Assert.is_nil(DbBase.transaction(function() return false end))
    Assert.eq(last(), "ROLLBACK;")
    Assert.errors(function()
        DbBase.transaction(function() error("boom") end)
    end)
    Assert.eq(last(), "ROLLBACK;", "抛错也要回滚，否则连接停在事务里")

    DbBase.close()
    clearMods()
end
