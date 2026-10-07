--[[--
插件 SQLite 连接与通用原语（$DATA/.moon/book.sqlite3）。

这里只有连接、执行原语、事务和建表登记，不认识任何业务表。
表模块与使用方同目录（如 `book/books_db.lua`、`http/cache.lua`），模块顶层经 `DB.schema` 登记建表。
表模块只写自己的表；要让别的核心表跟着变就调那张表模块的函数，feature 的表经 `utils.event` 订阅后自己改。
读查询可以 JOIN 别的表，但依赖只能单向：依附表可 JOIN books，books_db 只认识 chapters。

使用 WAL 模式 + busy_timeout=5000。禁止在 `workers.job` 子进程访问。

约定：
- 参数一律 `?` 绑定，禁止把用户值拼进 SQL 文本。
- 多语句写入走 `DB.transaction`，禁止手写 BEGIN/COMMIT/ROLLBACK；事务不可嵌套。
- 需要「是否真的命中行」时，同一连接上紧接着读 `SELECT changes();`。

@module koplugin.book.utils.db
--]]

local logger = require("utils.log")
local Paths = require("utils.paths")
local Perf = require("utils.perf")

local DB = {}

local conn = nil
local SLOW_QUERY_MS = 20

--- 打开 SQLite 连接（不改模块级 conn）
---@return SQLiteConnection|nil, string|nil
local function openSqlite()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then
        return nil, "sqlite module missing"
    end
    local path = Paths.dbPath()
    local c = SQ3.open(path)
    if not c then
        return nil, "open failed: " .. path
    end
    return c
end

--- stmt 用完即关，close 本身失败不影响主流程
---@param stmt SQLiteStatement|nil
local function closeStmt(stmt)
    if stmt then
        pcall(function()
            stmt:close()
        end)
    end
end

--- 执行无返回行的 SQL
---@param sql string
---@param ... any 绑定到 ? 占位符的值
---@return true|nil ok 成功为 true，失败为 nil
---@return any err 失败原因
function DB.exec(sql, ...)
    local c, open_err = DB.ensure()
    if not c then
        return nil, open_err
    end
    local argc = select("#", ...)
    local args = { ... }
    local stmt
    local started_at = Perf.now()
    local ok, err = pcall(function()
        if argc == 0 then
            c:exec(sql)
            return
        end
        stmt = c:prepare(sql)
        stmt:bind(unpack(args, 1, argc)):step()
    end)
    closeStmt(stmt)
    local elapsed_ms = Perf.elapsedMs(started_at)
    if not ok then
        logger.warn("book.db exec failed", err, sql, "params", unpack(args, 1, argc))
        return nil, err
    end
    if elapsed_ms >= SLOW_QUERY_MS then
        logger.dbg("book.db slow write", "ms", elapsed_ms, sql, "params", unpack(args, 1, argc))
    end
    return true
end

--- 在 BEGIN IMMEDIATE 事务里执行 fn：返回真值才提交，否则回滚。
--- fn 抛错时先回滚再原样抛出，不让连接停在未结束的事务里（之后的 BEGIN 会全部失败）。
---@generic T
---@param fn fun(): T
---@return T|nil result 提交成功时为 fn 的返回值
function DB.transaction(fn)
    if not DB.exec("BEGIN IMMEDIATE;") then return nil end
    local ok, result = pcall(fn)
    if ok and result and DB.exec("COMMIT;") then return result end
    DB.exec("ROLLBACK;")
    if not ok then error(result, 0) end
    return nil
end

--- 执行并取一行多列（失败返回 nil）
---@param sql string
---@param ... any 绑定到 ? 占位符的值
---@return any ...
function DB.rowexec(sql, ...)
    DB.ensure()
    if not conn then
        return nil
    end
    local argc = select("#", ...)
    local args = { ... }
    local stmt
    local started_at = Perf.now()
    local ok, row, names = pcall(function()
        stmt = conn:prepare(sql)
        if argc > 0 then
            stmt:bind(unpack(args, 1, argc))
        end
        return stmt:step({}, {})
    end)
    closeStmt(stmt)
    local elapsed_ms = Perf.elapsedMs(started_at)
    if not ok then
        logger.warn("book.db rowexec failed", row, sql, "params", unpack(args, 1, argc))
        return nil
    end
    if elapsed_ms >= SLOW_QUERY_MS then
        logger.dbg("book.db slow read", "rows", row and 1 or 0, "ms", elapsed_ms,
            sql, "params", unpack(args, 1, argc))
    end
    if not row then
        return nil
    end
    return unpack(row, 1, names and #names or #row)
end

--- 多行查询（conn:exec）；失败返回 nil, 0
---@param sql string
---@param ... any 绑定到 ? 占位符的值
---@return table|nil, number
function DB.query(sql, ...)
    DB.ensure()
    if not conn then
        return nil, 0
    end
    local argc = select("#", ...)
    local args = { ... }
    local stmt
    local started_at = Perf.now()
    local ok, result, nrows = pcall(function()
        if argc > 0 then
            stmt = conn:prepare(sql)
            stmt:bind(unpack(args, 1, argc))
            return stmt:resultset()
        end
        return conn:exec(sql)
    end)
    closeStmt(stmt)
    local elapsed_ms = Perf.elapsedMs(started_at)
    if not ok then
        logger.warn("book.db query failed", result, sql, "params", unpack(args, 1, argc))
        return nil, 0
    end
    if elapsed_ms >= SLOW_QUERY_MS then
        logger.dbg("book.db slow read", "rows", tonumber(nrows) or 0, "ms", elapsed_ms,
            sql, "params", unpack(args, 1, argc))
    end
    return result, nrows or 0
end

---@type { name: string, fn: fun(): boolean }[]
local schemas = {}
local schema_ready = false

--- 已登记的建表函数按登记顺序初始化；任何一步失败都回滚并返回错误。
---@return boolean, any
local function ensureSchema()
    local failed
    local ok = DB.transaction(function()
        for _idx, schema in ipairs(schemas) do
            if not schema.fn() then
                failed = schema.name
                return false
            end
        end
        return true
    end)
    if ok then return true end
    return false, failed and ("create schema failed: " .. failed) or "schema setup transaction failed"
end

--- 登记一张表的建表函数（表模块在模块顶层调用）。
--- fn 必须幂等（CREATE ... IF NOT EXISTS / 补列迁移），成功返回 true。
--- 连接未打开时只登记，open 时统一建；已打开则立即建（不另开事务：可能正处在调用方事务内）。
--- 查询 JOIN 了别的表时，表模块必须先 require 那张表的模块，否则全新库里表还不存在。
---@param name string 表名（只用于报错）
---@param fn fun(): boolean
function DB.schema(name, fn)
    schemas[#schemas + 1] = { name = name, fn = fn }
    if schema_ready and not fn() then
        logger.warn("book.db create schema failed", name)
    end
end

--- 打开（或复用）全局 SQLite 连接并确保 schema。
--- WAL 模式 + busy_timeout=5000。
--- SQL 在当前进程同步执行；调用方自行保证写操作顺序。
---@return SQLiteConnection|nil, string|nil
function DB.open()
    if conn then
        return conn
    end
    local c, err = openSqlite()
    if not c then
        logger.warn("book.db open failed", err)
        return nil, err
    end
    conn = c
    conn:exec("PRAGMA journal_mode=WAL;")
    conn:exec("PRAGMA busy_timeout=5000;")
    local schema_ok, schema_err = ensureSchema()
    if not schema_ok then
        logger.warn("book.db schema init failed", schema_err)
        DB.close()
        return nil, schema_err
    end
    schema_ready = true
    return conn
end

--- 关闭全局连接
function DB.close()
    schema_ready = false
    if conn then
        conn:close()
        conn = nil
    end
end

--- 确保连接可用（未开则 DB.open）。
---@return SQLiteConnection|nil, string|nil
function DB.ensure()
    local Job = package.loaded["workers.job"]
    if Job and Job.inSubProcess and Job.inSubProcess() then
        error("book.db: database access is forbidden in subprocess; use an instant job", 3)
    end

    if conn then
        return conn
    end
    return DB.open()
end

--- 把表里 (source_id, old_stable_id) 的行改挂到 new_stable_id（以 source_id/stable_id 为身份列的表通用）。
--- merge 为真时与新身份主键冲突的行保留新身份那份，旧身份残留删除；否则冲突即失败。
---@param tbl string 表名（调用方保证可信，不含用户输入）
---@param source_id string
---@param old_stable_id string
---@param new_stable_id string
---@param merge boolean|nil
---@return boolean
function DB.moveIdentity(tbl, source_id, old_stable_id, new_stable_id, merge)
    if not merge then
        return DB.exec("UPDATE " .. tbl .. " SET stable_id=? WHERE source_id=? AND stable_id=?;",
            new_stable_id, source_id, old_stable_id) ~= nil
    end
    return DB.exec("UPDATE OR IGNORE " .. tbl .. " SET stable_id=? WHERE source_id=? AND stable_id=?;",
        new_stable_id, source_id, old_stable_id) ~= nil
        and DB.exec("DELETE FROM " .. tbl .. " WHERE source_id=? AND stable_id=?;",
            source_id, old_stable_id) ~= nil
end

--- 把 source_id（单源字符串或多源表）收成 `col=?` / `col IN (…)`，并追加绑定参数。
---@param column string SQL 列名（调用方保证可信，不含用户输入）
---@param source_id string|string[]
---@param args table|nil 既有参数表；省略则新建
---@return string fragment
---@return table args
function DB.sourceClause(column, source_id, args)
    args = args or {}
    if type(source_id) ~= "table" then
        args[#args + 1] = source_id
        return column .. "=?", args
    end
    if #source_id == 1 then
        args[#args + 1] = source_id[1]
        return column .. "=?", args
    end
    local placeholders = {}
    for i = 1, #source_id do
        placeholders[i] = "?"
        args[#args + 1] = source_id[i]
    end
    return column .. " IN (" .. table.concat(placeholders, ",") .. ")", args
end

return DB
