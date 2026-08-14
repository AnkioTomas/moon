--[[--
utils.db：open 仅子进程 + reading_stats CRUD

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
    local text = "line1\nline2's"
    Assert.is_true(DbBase.exec("INSERT INTO sample VALUES (?,?,?)", text, nil, 3) ~= nil)
    Assert.eq(calls[1].sql, "INSERT INTO sample VALUES (?,?,?)")
    Assert.eq(calls[1].argc, 3)
    Assert.eq(calls[1].args[1], text)
    Assert.eq(calls[1].args[2], nil)
    Assert.eq(calls[1].args[3], 3)

    local got_text, got_nil, got_number = DbBase.rowexec(
        "SELECT text, nullable, number FROM sample WHERE text=?",
        text
    )
    Assert.eq(got_text, text)
    Assert.eq(got_nil, nil)
    Assert.eq(got_number, 3)
    Assert.eq(calls[2].args[1], text)

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
    Assert.eq(insert.argc, 6)
    Assert.eq(insert.args[1], "moon")
    Assert.eq(insert.args[2], "a.epub")
    Assert.eq(insert.args[4], 1000)

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

    Assert.is_true(StatsDB.deleteIds({ 7, 8 }))
    local deletes = 0
    for _, c in ipairs(calls) do
        if c.sql:find("DELETE FROM reading_stats", 1, true) then
            deletes = deletes + 1
        end
    end
    Assert.eq(deletes, 2)

    DbBase.close()
    clearMods()
end
