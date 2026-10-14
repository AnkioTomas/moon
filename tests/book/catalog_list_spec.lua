--[[--
book.catalog.listBooks：书库分页 / 筛选 / 搜索（books LEFT JOIN pending_progress）

@module tests.book.catalog_list_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

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
        "workers.job",
        "lua-ljsqlite3/init",
        "ffi/sha2",
        "utils.db",
        "book.books_db",
        "book.chapters_db",
        "http.cache", "utils.event",
        "book.note_db",
        "book.progress_db",
        "book.stats_db",
        "features.xray.db", "book.catalog",
    }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end

do
    local calls = {}
    local fail_count = false
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
                    if fail_count then error("database is locked") end
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
                    if sql:find("COUNT(*)", 1, true) and sql:find("GROUP BY", 1, true) then
                        if sql:find("WHEN read_state=1 THEN 'read'", 1, true) then
                            return { { "read", "unread" }, { 2, 4 } }, 2
                        end
                        if sql:find("GROUP BY source_id", 1, true) then
                            return { { "local", "wechat" }, { 3, 5 } }, 2
                        end
                        if sql:find("CASE WHEN series", 1, true) then
                            return { { "第一辑", "" }, { 5, 2 } }, 2
                        end
                        return { { "sub", "" }, { 3, 2 } }, 2
                    end
                    return {
                        { "local" },
                        { "/books/a.epub" },
                        { "书名" },
                        { "作者" },
                        { 42 },
                        { "sub" },
                        { "第一辑" },
                        { "介绍" },
                        { "https://img.test/a.jpg" },
                        { 1000 },
                        { 1 },
                        { "/cache/a.epub" },
                        { 1 },
                    }, 1
                end,
                close = function() end,
            }
        end,
    }

    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return connection end }
    end
    package.loaded["utils.db"] = nil
    package.loaded["book.books_db"] = nil
    package.loaded["book.progress_db"] = nil
    package.loaded["book.catalog"] = nil

    local DbBase = require("utils.db")
    local Catalog = require("book.catalog")
    require("book.progress_db")
    DbBase.open()

    -- 无筛选：仅 source_id；LIMIT/OFFSET 绑定
    local rows, count = Catalog.listBooks("local", { limit = 24, offset = 48 })
    Assert.eq(count, 7)
    Assert.eq(#rows, 1)
    Assert.eq(rows[1].source_id, "local")
    Assert.eq(rows[1].stable_id, "/books/a.epub")
    Assert.eq(rows[1].title, "书名")
    Assert.eq(rows[1].percent, 42)
    Assert.eq(rows[1].series, "第一辑")
    Assert.is_true(rows[1].downloaded)
    Assert.eq(rows[1].cover, "https://img.test/a.jpg")
    Assert.eq(rows[1].inserted_at, 1000)
    Assert.eq(rows[1].read_state, 1)
    Assert.eq(rows[1].path, "/cache/a.epub")
    Assert.eq(rows[1].deleted, 0)
    local count_q = calls[#calls - 1]
    Assert.is_true(count_q.sql:find("WHERE source_id=%?", 1) ~= nil or count_q.sql:find("source_id=?", 1, true) ~= nil)
    Assert.is_true(count_q.sql:find("b.deleted=0", 1, true) ~= nil)
    Assert.is_false(count_q.sql:find("category=", 1, true) ~= nil)
    local list_q = calls[#calls]
    Assert.is_true(list_q.sql:find("b.inserted_at", 1, true) ~= nil)
    Assert.is_true(list_q.sql:find("is_new", 1, true) == nil)
    Assert.is_true(list_q.sql:find("LIMIT ? OFFSET ?", 1, true) ~= nil)
    Assert.eq(list_q.args[#list_q.args - 1], 24)
    Assert.eq(list_q.args[#list_q.args], 48)

    -- 分类 + 系列 + 搜索：AND 条件与 LIKE 参数
    calls = {}
    rows, count = Catalog.listBooks("local", {
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

    calls = {}
    Catalog.listBooks("local", { read_status = "unread" })
    Assert.is_true(calls[1].sql:find("b.read_state<>1", 1, true) ~= nil)
    calls = {}
    Catalog.listBooks("local", { read_status = "read" })
    Assert.is_true(calls[1].sql:find("b.read_state=1", 1, true) ~= nil)
    calls = {}
    Catalog.listBooks("local", { uncategorized = true })
    Assert.is_true(calls[1].sql:find("b.category IS NULL OR b.category=''", 1, true) ~= nil)
    calls = {}
    Catalog.listBooks("local", { unseries = true })
    Assert.is_true(calls[1].sql:find("b.series IS NULL OR b.series=''", 1, true) ~= nil)
    calls = {}
    Catalog.listBooks("local", { unauthor = true, author = "鲁迅" })
    Assert.is_true(calls[1].sql:find("b.authors IS NULL OR b.authors=''", 1, true) ~= nil)
    Assert.is_nil(calls[1].sql:find("b.authors=?", 1, true), "空桶优先于组名")
    calls = {}
    Catalog.listBooks("local", { author = "鲁迅" })
    Assert.is_true(calls[1].sql:find("AND b.authors=?", 1, true) ~= nil)
    Assert.eq(calls[1].args[2], "鲁迅")
    calls = {}
    Catalog.listBooks({ "local", "wechat" }, { source_id = "wechat" })
    Assert.is_true(calls[1].sql:find("b.source_id IN (?,?)", 1, true) ~= nil)
    Assert.is_true(calls[1].sql:find("AND b.source_id=?", 1, true) ~= nil)
    Assert.eq(calls[1].args[1], "local")
    Assert.eq(calls[1].args[2], "wechat")
    Assert.eq(calls[1].args[3], "wechat")
    calls = {}
    Catalog.listBooks("local", { downloaded = true, chapter_sources = { "wechat", "jdread" } })
    Assert.is_true(calls[1].sql:find("CASE WHEN b.source_id IN (?,?) THEN", 1, true) ~= nil)
    Assert.is_true(calls[1].sql:find("COUNT(DISTINCT c.chapter_idx) = MAX(c.chapter_idx) - MIN(c.chapter_idx) + 1", 1, true) ~= nil)
    Assert.is_nil(calls[1].sql:find("b.toc", 1, true), "已下载不看目录")
    Assert.is_true(calls[1].sql:find("FROM chapters c", 1, true) ~= nil)
    Assert.is_true(calls[1].sql:find("COALESCE(b.path, '')<>''", 1, true) ~= nil)
    Assert.eq(calls[1].args[1], "local")
    Assert.eq(calls[1].args[2], "wechat")
    Assert.eq(calls[1].args[3], "jdread")


    -- 查询出错：不能当成 0 本，带 err 返回
    fail_count = true
    local err_rows, err_count, err = Catalog.listBooks("local", { limit = 24 })
    fail_count = false
    Assert.len(err_rows, 0)
    Assert.eq(err_count, 0)
    Assert.not_nil(err, "库查询出错要带错误，图书馆页据此显示「加载失败」")

    -- 「最近阅读」只列读过的书：计数与列表都用 INNER JOIN，没进度行的书不进来。
    calls = {}
    Catalog.listBooks("local", { sort = "recent_read", limit = 24 })
    Assert.is_true(calls[1].sql:find("FROM books b JOIN pending_progress p", 1, true) ~= nil,
        "计数也按「读过」筛")
    Assert.is_nil(calls[1].sql:find("LEFT JOIN pending_progress", 1, true))
    Assert.is_true(calls[1].sql:find("(b.deleted=0 OR b.sync_status=1)", 1, true) ~= nil,
        "卷行这种非书架成员也要列进最近阅读")
    Assert.is_true(calls[2].sql:find("FROM books b JOIN pending_progress p", 1, true) ~= nil)
    Assert.is_true(calls[2].sql:find("ORDER BY COALESCE(p.updated_at, 0) DESC", 1, true) ~= nil,
        "按最近一次读排序")
    -- 其它排序仍 LEFT JOIN + 只在架：按书名 / 加入时间排要列出全库。
    calls = {}
    Catalog.listBooks("local", { sort = "title" })
    Assert.is_true(calls[1].sql:find("LEFT JOIN pending_progress", 1, true) ~= nil)
    Assert.is_true(calls[1].sql:find("b.deleted=0", 1, true) ~= nil)
    calls = {}
    Catalog.listBooks("local", { sort = "recent_added" })
    Assert.is_true(calls[1].sql:find("LEFT JOIN pending_progress", 1, true) ~= nil)
    Assert.is_true(calls[1].sql:find("b.deleted=0", 1, true) ~= nil)

    DbBase.close()
    clearMods()
end
