--[[--
utils.db：open 仅子进程 + BookDB.md5Map

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

-- ── md5Map：DESC 结果保留首条 ───────────────────────────
do
    local prepared_sql
    local bound_source
    local connection = {
        exec = function()
            return nil, 0
        end,
        close = function() end,
        prepare = function(_, sql)
            prepared_sql = sql
            return {
                bind = function(self, source_id)
                    bound_source = source_id
                    return self
                end,
                resultset = function()
                    return {
                        { "shared", "shared", "unique" },
                        { "new.epub", "old.epub", "only.epub" },
                    }, 3
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
    local map = BookDB.md5Map("moon")
    Assert.is_true(prepared_sql:find("source_id=?", 1, true) ~= nil)
    Assert.eq(bound_source, "moon")
    Assert.eq(map.shared, "new.epub")
    Assert.eq(map.unique, "only.epub")

    DbBase.close()
    clearMods()
end
