--[[--
book.books_db：书架分类 / 系列 / 阅读状态 / 来源 / 已下载计数查询

@module tests.book.books_db_filters_spec
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
        "features.xray.db",
    }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end

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

    local DbBase = require("utils.db")
    local BookDB = require("book.books_db")
    DbBase.open()

    calls = {}
    Assert.eq(BookDB.downloadedCountBySource({ "local", "wechat" }, { "wechat" }), 7)
    Assert.is_true(calls[1].sql:find("b.deleted=0 AND (CASE WHEN b.source_id=? THEN", 1, true) ~= nil)
    Assert.eq(calls[1].args[3], "wechat")

    -- 分类列表
    local cats = BookDB.categoriesBySource("local")
    Assert.eq(#cats, 2)
    Assert.eq(cats[1], "sub")
    local series = BookDB.seriesBySource("local")
    Assert.eq(#series, 2)
    Assert.eq(series[1], "第一辑")
    local category_counts = BookDB.categoryCountsBySource("local")
    Assert.eq(category_counts[1].category, "sub")
    Assert.eq(category_counts[1].count, 3)
    Assert.eq(category_counts[2].category, "")
    Assert.eq(category_counts[2].count, 2)
    local source_counts = BookDB.sourceCountsBySource({ "local", "wechat" })
    Assert.eq(source_counts[1].source_id, "local")
    Assert.eq(source_counts[1].count, 3)
    Assert.eq(source_counts[2].source_id, "wechat")
    Assert.eq(source_counts[2].count, 5)
    local series_counts = BookDB.seriesCountsBySource("local")
    Assert.eq(series_counts[1].series, "第一辑")
    Assert.eq(series_counts[1].count, 5)
    Assert.eq(series_counts[2].series, "")
    local read_counts = BookDB.readStatusCountsBySource("local")
    Assert.eq(#read_counts, 2)
    Assert.eq(read_counts[1].status, "read")
    Assert.eq(read_counts[1].count, 2)
    Assert.eq(read_counts[2].status, "unread")
    Assert.eq(read_counts[2].count, 4)

    DbBase.close()
    clearMods()
end
