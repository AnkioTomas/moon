--[[--
插件 SQLite 连接与通用原语（$DATA/.moon/book.sqlite3）。

表由 open → ensureSchema 一次性建立。

使用 WAL 模式 + busy_timeout=5000。

@module koplugin.book.db.base
--]]

local logger = require("logger")
local Paths = require("utils.paths")
local Context = require("workers.context")

local Base = {}

local conn = nil

--- 数据库只允许在主进程访问。
--- 后台子进程需要把结果通过 workers.simple_job 回调交回主进程后再落库。
---@return nil
local function assertMainProcess()
    if Context.inSubProcess() then
        error("book.db: database access is forbidden in subprocess; use workers.simple_job", 3)
    end
end

--- 打开 SQLite 连接（不改模块级 conn）
---@return userdata|nil, string|nil
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
---@param stmt userdata|nil
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
---@return boolean|nil, any
function Base.exec(sql, ...)
    assertMainProcess()
    if not conn then
        return nil
    end
    local argc = select("#", ...)
    local args = { ... }
    local stmt
    local ok, err = pcall(function()
        if argc == 0 then
            conn:exec(sql)
            return
        end
        stmt = conn:prepare(sql)
        stmt:bind(unpack(args, 1, argc)):step()
    end)
    closeStmt(stmt)
    if not ok then
        logger.warn("book.db exec failed", err, sql and sql:sub(1, 120))
        return nil, err
    end
    return true
end

--- 执行并取一行多列（失败返回 nil）
---@param sql string
---@param ... any 绑定到 ? 占位符的值
---@return any ...
function Base.rowexec(sql, ...)
    assertMainProcess()
    if not conn then
        return nil
    end
    local argc = select("#", ...)
    local args = { ... }
    local stmt
    local ok, row, names = pcall(function()
        stmt = conn:prepare(sql)
        if argc > 0 then
            stmt:bind(unpack(args, 1, argc))
        end
        return stmt:step({}, {})
    end)
    closeStmt(stmt)
    if not ok then
        logger.warn("book.db rowexec failed", row, sql and sql:sub(1, 120))
        return nil
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
function Base.query(sql, ...)
    assertMainProcess()
    if not conn then
        return nil, 0
    end
    local argc = select("#", ...)
    local args = { ... }
    local stmt
    local ok, result, nrows = pcall(function()
        if argc > 0 then
            stmt = conn:prepare(sql)
            stmt:bind(unpack(args, 1, argc))
            return stmt:resultset()
        end
        return conn:exec(sql)
    end)
    closeStmt(stmt)
    if not ok then
        logger.warn("book.db query failed", result, sql and sql:sub(1, 120))
        return nil, 0
    end
    return result, nrows or 0
end

--- 校验 source_id；非法返回 nil
---@param source_id string
---@return string|nil
function Base.requireSourceId(source_id)
    if type(source_id) ~= "string" or source_id == "" then
        return nil
    end
    return source_id
end

local schema_modules = {
    "db.book",
    "db.chapter",
    "db.http",
    "db.note",
    "db.progress",
    "db.stats",
    "db.toc",
    "db.xray",
}

--- 建表模块按固定顺序初始化；任何一步失败都回滚并返回错误。
---@return boolean, any
local function ensureSchema()
    if not Base.exec("BEGIN IMMEDIATE;") then
        return false, "begin schema setup failed"
    end
    for _, module_name in ipairs(schema_modules) do
        local module = require(module_name)
        if not module.ensureSchema() then
            Base.exec("ROLLBACK;")
            return false, "create schema failed: " .. module_name
        end
    end

    if not Base.exec("COMMIT;") then
        Base.exec("ROLLBACK;")
        return false, "commit schema setup failed"
    end
    return true
end

--- 打开（或复用）全局 SQLite 连接并确保 schema。
--- WAL 模式 + busy_timeout=5000。
--- SQL 在当前进程同步执行；调用方自行保证写操作顺序。
---@return userdata|nil, string|nil
function Base.open()
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
        Base.close()
        return nil, schema_err
    end
    return conn
end

--- 关闭全局连接
---@return nil
function Base.close()
    if conn then
        conn:close()
        conn = nil
    end
end

--- 确保连接可用（未开则 Base.open）。
--- 读写操作均在当前进程同步执行。
---@return userdata|nil, string|nil
function Base.ensure()
    if Context.inSubProcess() then
        error("book.db: database access is forbidden in subprocess; use workers.simple_job", 3)
    end

    if conn then
        return conn
    end
    return Base.open()
end

return Base
