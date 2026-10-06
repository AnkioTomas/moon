--[[--
utils.db：open、子进程禁用、参数绑定、建表登记与身份迁移原语

@module tests.utils.db_spec
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

-- ── 主进程 open 应成功（WAL 模式 + busy_timeout，读操作安全）───
do
    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return { exec = function() end, close = function() end } end }
    end
    package.loaded["utils.db"] = nil

    local DbBase = require("utils.db")
    local ok, conn = pcall(DbBase.open)
    Assert.is_true(ok)
    Assert.is_true(conn ~= nil)

    -- sourceClause：单源 =?；单元素表同单源；多源 IN
    local frag, args = DbBase.sourceClause("source_id", "local")
    Assert.eq(frag, "source_id=?")
    Assert.eq(args[1], "local")
    frag, args = DbBase.sourceClause("b.source_id", { "local" })
    Assert.eq(frag, "b.source_id=?")
    frag, args = DbBase.sourceClause("source_id", { "local", "wechat" })
    Assert.eq(frag, "source_id IN (?,?)")
    Assert.eq(args[1], "local")
    Assert.eq(args[2], "wechat")
    clearMods()
end

-- ── 子进程禁止通过数据库原语隐式打开连接 ────────────────
do
    local opened = 0

    stubDbDeps()
    -- Base.ensure 只看 package.loaded["workers.job"]，不 require。
    package.loaded["workers.job"] = {
        inSubProcess = function() return true end,
    }
    package.preload["lua-ljsqlite3/init"] = function()
        return {
            open = function()
                opened = opened + 1
                return { exec = function() end, close = function() end }
            end,
        }
    end
    package.loaded["utils.db"] = nil

    local DbBase = require("utils.db")
    Assert.errors(function()
        DbBase.exec("DELETE FROM books;")
    end, "database access is forbidden in subprocess")
    Assert.eq(opened, 0)
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

    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return connection end }
    end
    package.loaded["utils.db"] = nil

    local DbBase = require("utils.db")
    DbBase.open()
    -- 建表走无参 conn:exec，不进 prepare；首个 prepare 就是下面这条 INSERT
    local text = "line1\nline2's"
    Assert.is_true(DbBase.exec("INSERT INTO sample VALUES (?,?,?)", text, nil, 3) ~= nil)
    local insert_call
    for _, call in ipairs(calls) do
        if call.sql == "INSERT INTO sample VALUES (?,?,?)" then
            insert_call = call
            break
        end
    end
    Assert.not_nil(insert_call)
    Assert.eq(insert_call.argc, 3)
    Assert.eq(insert_call.args[1], text)
    Assert.eq(insert_call.args[2], nil)
    Assert.eq(insert_call.args[3], 3)

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

--- 只记 SQL 文本的假连接；fail_on 命中的语句抛错（模拟 SQLite 失败）。
---@param fail_on string|nil
local function loadRecording(fail_on)
    local execs = {}
    local connection = {
        exec = function(_, sql)
            execs[#execs + 1] = sql
            if fail_on and sql:find(fail_on, 1, true) then error("boom") end
        end,
        close = function() end,
        prepare = function(_, sql)
            execs[#execs + 1] = sql
            return {
                bind = function(self) return self end,
                step = function()
                    if fail_on and sql:find(fail_on, 1, true) then error("boom") end
                    return nil
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
    return require("utils.db"), execs
end

-- ── schema：open 时按登记顺序在一个事务里建表；已打开后登记的表立即建 ──
do
    local DbBase, execs = loadRecording()
    local order = {}
    DbBase.schema("a", function()
        order[#order + 1] = "a"
        return DbBase.exec("CREATE TABLE IF NOT EXISTS a (x);") ~= nil
    end)
    DbBase.schema("b", function()
        order[#order + 1] = "b"
        return DbBase.exec("CREATE TABLE IF NOT EXISTS b (x);") ~= nil
    end)
    Assert.eq(#order, 0, "未打开连接时只登记不执行")

    Assert.not_nil(DbBase.open())
    Assert.eq(table.concat(order, ","), "a,b")
    local joined = table.concat(execs, "\n")
    local begin_at = joined:find("BEGIN IMMEDIATE;", 1, true)
    Assert.is_true(begin_at ~= nil and begin_at < joined:find("CREATE TABLE IF NOT EXISTS a", 1, true))
    Assert.is_true(joined:find("CREATE TABLE IF NOT EXISTS b", 1, true) < joined:find("COMMIT;", 1, true))

    DbBase.schema("late", function()
        order[#order + 1] = "late"
        return DbBase.exec("CREATE TABLE IF NOT EXISTS late (x);") ~= nil
    end)
    Assert.eq(order[#order], "late", "已打开连接时晚到的表立即建")

    -- 重开连接时全部登记重新执行（幂等建表）
    DbBase.close()
    order = {}
    Assert.not_nil(DbBase.open())
    Assert.eq(table.concat(order, ","), "a,b,late")

    DbBase.close()
    clearMods()
end

-- ── schema：任一建表失败整体回滚，open 返回错误且不留连接 ──
do
    local DbBase, execs = loadRecording("CREATE TABLE IF NOT EXISTS bad")
    DbBase.schema("good", function()
        return DbBase.exec("CREATE TABLE IF NOT EXISTS good (x);") ~= nil
    end)
    DbBase.schema("bad", function()
        return DbBase.exec("CREATE TABLE IF NOT EXISTS bad (x);") ~= nil
    end)
    local conn, err = DbBase.open()
    Assert.is_nil(conn)
    Assert.matches(err, "create schema failed: bad")
    Assert.eq(execs[#execs], "ROLLBACK;")
    clearMods()
end

-- ── moveIdentity：普通改名直接 UPDATE；收编 UPDATE OR IGNORE 后删旧身份残留，全参数化 ──
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
                step = function() return nil end,
                close = function() end,
            }
        end,
    }
    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return connection end }
    end
    package.loaded["utils.db"] = nil
    local DbBase = require("utils.db")
    DbBase.open()

    Assert.is_true(DbBase.moveIdentity("notes", "local", "/old'.epub", "/new.epub"))
    Assert.eq(#calls, 1)
    Assert.eq(calls[1].sql, "UPDATE notes SET stable_id=? WHERE source_id=? AND stable_id=?;")
    Assert.eq(calls[1].args[1], "/new.epub")
    Assert.eq(calls[1].args[2], "local")
    Assert.eq(calls[1].args[3], "/old'.epub")

    calls = {}
    Assert.is_true(DbBase.moveIdentity("notes", "local", "/old.epub", "/new.epub", true))
    Assert.eq(#calls, 2)
    Assert.eq(calls[1].sql, "UPDATE OR IGNORE notes SET stable_id=? WHERE source_id=? AND stable_id=?;")
    Assert.eq(calls[2].sql, "DELETE FROM notes WHERE source_id=? AND stable_id=?;")
    Assert.eq(calls[2].args[1], "local")
    Assert.eq(calls[2].args[2], "/old.epub")

    DbBase.close()
    clearMods()
end

-- ── 全部表模块：各自登记建表，建表语句自带全部列，从不 DROP TABLE ──
do
    local DbBase, execs = loadRecording()
    for _idx, name in ipairs({
        "book.books_db", "book.chapters_db", "book.note_db", "book.progress_db",
        "book.stats_db", "features.xray.db",
    }) do
        require(name)
    end
    local opened, open_err = DbBase.open()
    DbBase.close()
    clearMods()

    Assert.not_nil(opened)
    Assert.is_nil(open_err)
    local schema = table.concat(execs, "\n")
    for _idx, tbl in ipairs({ "books", "chapters", "notes", "pending_progress", "reading_stats", "xray_entities" }) do
        Assert.is_true(schema:find("CREATE TABLE IF NOT EXISTS " .. tbl, 1, true) ~= nil, tbl)
    end
    Assert.is_true(schema:find("reader_prefs TEXT", 1, true) ~= nil)
    Assert.is_true(schema:find("extra TEXT", 1, true) ~= nil)
    Assert.is_true(schema:find("idx_reading_stats_identity", 1, true) ~= nil)
    Assert.is_false(schema:find("PRAGMA user_version", 1, true) ~= nil)
    Assert.is_true(schema:find("record_type TEXT NOT NULL", 1, true) ~= nil)
    Assert.is_false(schema:find("DROP TABLE", 1, true) ~= nil)
    Assert.is_false(schema:find("UPDATE books", 1, true) ~= nil, "进度表建表不直接改 books")
end
