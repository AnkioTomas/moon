--[[--
book.stats_db：reading_stats CRUD 与聚合查询

@module tests.book.stats_db_spec
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
    package.loaded["utils.settings"] = nil
    package.preload["utils.settings"] = function()
        return { getSource = function() return {} end }
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

-- ── reading_stats：add / count / exists / replaceSynced 全参数化 ──
do
    local calls = {}
    local connection = {
        exec = function(_, sql) calls[#calls + 1] = { sql = sql } end,
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
                step = function(_, ...)
                    if sql:find("COUNT", 1, true) then
                        return { 2 }, { "COUNT(*)" }
                    end
                    -- exists：只有 a.epub 那条算命中
                    if sql:find("SELECT 1 FROM reading_stats", 1, true) then
                        if call.args and call.args[2] == "a.epub" then
                            return { 1 }, { "1" }
                        end
                        return nil
                    end
                    return nil
                end,
                resultset = function()
                    if sql:find("chapter_idx", 1, true) then
                        return {
                            { 7, 8 },
                            { "a.epub", "b.epub" },
                            { 3, 4 },
                            { 1000, 2000 },
                            { 30, 45 },
                            { 300, 400 },
                            { 1, 2 },
                            { 0.5, 0.75 },
                            { 0, 1 },
                        }, 2
                    end
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

    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return connection end }
    end
    package.loaded["utils.db"] = nil
    package.loaded["book.stats_db"] = nil

    local DbBase = require("utils.db")
    local StatsDB = require("book.stats_db")
    DbBase.open()

    Assert.is_true(StatsDB.add({
        source_id = "moon",
        stable_id = "a.epub",
        record_type = "page",
        page = 3,
        start_time = 1000,
        duration = 30,
        total_pages = 300,
    }))
    local insert = calls[#calls]
    Assert.is_true(insert.sql:find("INSERT INTO reading_stats", 1, true) ~= nil)
    Assert.eq(insert.argc, 12)
    Assert.eq(insert.args[1], "moon")
    Assert.eq(insert.args[2], "a.epub")
    Assert.eq(insert.args[4], 3)
    Assert.eq(insert.args[10], 0)
    Assert.eq(insert.args[11], 1)
    Assert.eq(insert.args[12], 0)

    -- 非法时长仍拒绝
    Assert.is_false(StatsDB.add({ source_id = "moon", stable_id = "a", start_time = 1, duration = 0 }))

    local hit = { source_id = "moon", stable_id = "a.epub", record_type = "page", page = 3,
        start_time = 1000, duration = 30, total_pages = 300 }
    local miss = { source_id = "moon", stable_id = "b.epub", record_type = "page", page = 4,
        start_time = 2000, duration = 45, total_pages = 400 }
    Assert.is_true(StatsDB.exists(hit))
    Assert.is_false(StatsDB.exists(miss))
    local probe = calls[#calls]
    Assert.is_true(probe.sql:find("SELECT 1 FROM reading_stats", 1, true) ~= nil)
    Assert.eq(probe.argc, 6, "exists 必须走参数化唯一索引查询")

    -- replaceSynced：清理 + 写入同事务；命中的算 skipped，未命中的算 imported
    local mark = #calls
    local saved = StatsDB.replaceSynced("moon", {}, { hit, miss })
    Assert.eq(saved.imported, 1)
    Assert.eq(saved.skipped, 1)
    local begun, deleted, committed = 0, 0, 0
    for i = mark + 1, #calls do
        local c = calls[i]
        if c.sql:find("BEGIN IMMEDIATE", 1, true) then begun = begun + 1 end
        if c.sql:find("DELETE FROM reading_stats", 1, true) then deleted = deleted + 1 end
        if c.sql:find("COMMIT", 1, true) then committed = committed + 1 end
    end
    Assert.eq(begun, 1)
    Assert.eq(deleted, 1)
    Assert.eq(committed, 1)

    local full_mark = #calls
    local emptied = StatsDB.replaceSynced("moon", { mode = "all_synced" }, {})
    Assert.eq(emptied.imported, 0)
    local full_delete
    for i = full_mark + 1, #calls do
        if calls[i].sql:find("sync_status=1", 1, true) then full_delete = calls[i] end
    end
    Assert.not_nil(full_delete, "空的全量快照也必须清掉旧远端记录")
    Assert.eq(full_delete.args[1], "moon")

    local pending = StatsDB.unsyncedBySource("moon")
    Assert.eq(#pending, 2)
    Assert.is_true(StatsDB.markSynced({ 7, 8 }))
    local updates = 0
    for _, c in ipairs(calls) do
        if c.sql:find("UPDATE reading_stats SET sync_status=1", 1, true) then
            updates = updates + 1
        end
    end
    Assert.eq(updates, 1)
    Assert.eq(calls[#calls - 1].argc, 2)

    DbBase.close()
    clearMods()
end

-- ── reading_stats 聚合查询（本地洞察）──
do
    local day1 = os.date("%Y-%m-%d", os.time() - 86400)
    local day2 = os.date("%Y-%m-%d")
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
                    if sql:find("record_type='total'", 1, true) then
                        if call.args and call.args[1] == "wechat" then
                            return { 7200 }, { "total" }
                        end
                        return nil
                    end
                    if sql:find("MAX(CASE WHEN record_type='page_rollup'", 1, true) then
                        return { 3660, 0, 3, 2000 }, { "s", "f", "c", "m" }
                    end
                    return nil
                end,
                resultset = function()
                    if sql:find("ORDER BY day, seconds DESC", 1, true) then
                        return {
                            { day2 },
                            { "local" },
                            { "/books/a.epub" },
                            { 600 },
                            { 10 },
                            { 20 },
                        }, 1
                    end
                    if sql:find("GROUP BY day, stable_id, record_type", 1, true) then
                        return {
                            { day1, day2 },
                            { "/books/a.epub", "/books/a.epub" },
                            { "page", "page" },
                            { 300, 600 },
                            { 5, 10 },
                            { 0, 0 },
                        }, 2
                    end
                    if sql:find("ORDER BY day DESC", 1, true) then
                        return {
                            { day2, day1 },
                            { 600, 300 },
                            { 10, 5 },
                        }, 2
                    end
                    return {
                        { day1, day2 },
                        { 300, 600 },
                        { 5, 10 },
                    }, 2
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
    package.loaded["book.stats_db"] = nil

    local DbBase = require("utils.db")
    local StatsDB = require("book.stats_db")
    DbBase.open()

    local s = StatsDB.summaryBySource("local")
    Assert.eq(s.total_seconds, 900)
    Assert.eq(s.total_pages, 15)
    Assert.eq(s.last7_seconds, 900)
    Assert.eq(s.longest_day_seconds, 600)

    local remote = StatsDB.summaryBySource("wechat")
    Assert.eq(remote.total_seconds, 7200,
        "微信累计总量必须覆盖不完整的明细桶求和")

    local daily = StatsDB.dailyBySource("local")
    Assert.eq(#daily, 2)
    Assert.eq(daily[1].ymd, day1)
    Assert.eq(daily[2].seconds, 600)

    local books = StatsDB.dailyBooksBySource("local")
    Assert.eq(#books, 1)
    Assert.eq(books[1].source_id, "local")
    Assert.eq(books[1].stable_id, "/books/a.epub")
    Assert.eq(books[1].max_page, 10)
    Assert.eq(books[1].max_total_pages, 20)
    local sb = StatsDB.summaryByBook("local", "/books/a.epub")
    Assert.eq(sb.total_seconds, 3660)
    Assert.eq(sb.pages, 3)
    Assert.eq(sb.last_read, 2000)
    Assert.eq(sb.first_read, 0)
    local first_q = calls[#calls]
    Assert.is_true(first_q.sql:find("MIN(start_time)", 1, true) ~= nil)
    Assert.eq(first_q.args[1], "local")
    Assert.eq(first_q.args[2], "/books/a.epub")
    local sb_q = calls[#calls - 1]
    Assert.is_true(sb_q.sql:find("AND stable_id=?", 1, true) ~= nil)
    Assert.eq(sb_q.args[1], 0, "无云端快照时快照时间按 0 绑定")
    Assert.eq(sb_q.args[2], "local")
    Assert.eq(sb_q.args[3], "/books/a.epub")

    -- 按书按天聚合（详情页最近几天卡片）：日期倒序 + LIMIT 绑定
    local bd = StatsDB.dailyByBook("local", "/books/a.epub", 5)
    Assert.eq(#bd, 2)
    Assert.eq(bd[1].ymd, day2)
    Assert.eq(bd[1].seconds, 600)
    Assert.eq(bd[1].pages, 10)
    Assert.eq(bd[2].ymd, day1)
    local bd_q = calls[#calls]
    Assert.is_true(bd_q.sql:find("AND r.stable_id=?", 1, true) ~= nil)
    Assert.is_true(bd_q.sql:find("LIMIT ?", 1, true) ~= nil)
    Assert.eq(bd_q.args[1], "local")
    Assert.eq(bd_q.args[2], "/books/a.epub")
    Assert.eq(bd_q.args[#bd_q.args], 5, "LIMIT 绑定在最后")
    -- 全部参数化：source_id 绑定，不以字面量拼进 SQL
    for _, c in ipairs(calls) do
        Assert.is_false(c.sql:find("'local'", 1, true) ~= nil)
    end

    DbBase.close()
    clearMods()
end
