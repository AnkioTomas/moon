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

-- ── 主进程 open 必须失败 ────────────────────────────────
do
    stubTask(false)
    stubDbDeps()
    package.preload["lua-ljsqlite3/init"] = function()
        return { open = function() return { exec = function() end, close = function() end } end }
    end
    package.loaded["utils.db.base"] = nil

    local DbBase = require("utils.db.base")
    local ok, err = pcall(DbBase.open)
    Assert.is_true(not ok)
    Assert.is_true(type(err) == "string" and err:find("Task subprocess", 1, true) ~= nil)
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

-- ── md5Map：DESC 结果保留首条 ───────────────────────────
do
    local connection = {
        exec = function(_, sql)
            if sql:find("SELECT md5, filename FROM books", 1, true) then
                return {
                    { "shared", "shared", "unique" },
                    { "new.epub", "old.epub", "only.epub" },
                }, 3
            end
            return nil, 0
        end,
        close = function() end,
        rowexec = function() return nil end,
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
    Assert.eq(map.shared, "new.epub")
    Assert.eq(map.unique, "only.epub")

    DbBase.close()
    clearMods()
end
