--[[--
插件 SQLite 连接与通用原语（$DATA/.moon/book.sqlite3）

表由 open → ensureSchema 一次 CREATE IF NOT EXISTS。
不做 schema/legacy 迁移。

只允许在 Task 子进程内 open（Task.inSubProcess()）。
主进程禁止碰库。

@module koplugin.book.utils.db.base
--]]

local logger = require("logger")
local md5 = require("ffi/sha2").md5
local Paths = require("utils.paths")

local Base = {}

local conn = nil

--- 插件 SQLite 文件路径
---@return string
local function dbPath()
    return Paths.dbPath()
end

--- 打开 SQLite 连接（不改模块级 conn）
---@return userdata|nil, string|nil
local function openSqlite()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then
        return nil, "sqlite module missing"
    end
    Paths.ensureSettings()
    local path = dbPath()
    local c = SQ3.open(path)
    if not c then
        return nil, "open failed: " .. path
    end
    return c
end

--- 执行无返回行的 SQL
---@param sql string
---@param ... any 绑定到 ? 占位符的值
---@return boolean|nil, any
function Base.exec(sql, ...)
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
    if stmt then
        pcall(function()
            stmt:close()
        end)
    end
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
    if stmt then
        pcall(function()
            stmt:close()
        end)
    end
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
    if stmt then
        pcall(function()
            stmt:close()
        end)
    end
    if not ok then
        logger.warn("book.db query failed", result, sql and sql:sub(1, 120))
        return nil, 0
    end
    return result, nrows or 0
end

--- 校验并消毒 source_id；非法返回 nil
---@param source_id string
---@return string|nil
function Base.requireSourceId(source_id)
    if type(source_id) ~= "string" or source_id == "" then
        return nil
    end
    return Paths.sanitizeSourceId(source_id)
end

--- 由 source_id + stable_id 生成 book_key（md5）
---@param source_id string
---@param stable_id string
---@return string|nil
function Base.bookKeyFor(source_id, stable_id)
    if type(stable_id) ~= "string" or stable_id == "" then
        return nil
    end
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return nil
    end
    return md5(source_id .. ":" .. stable_id)
end

--- 首次打开时 CREATE IF NOT EXISTS 全表
---@return nil
local function ensureSchema()
    Base.exec([[
CREATE TABLE IF NOT EXISTS books (
  book_key   TEXT PRIMARY KEY,
  source_id  TEXT NOT NULL,
  stable_id  TEXT NOT NULL,
  filename   TEXT,
  md5        TEXT,
  title      TEXT,
  authors    TEXT,
  percent    REAL DEFAULT 0,
  category   TEXT,
  favorite   TEXT,
  series     TEXT,
  intro      TEXT,
  fetched_at INTEGER NOT NULL DEFAULT 0,
  UNIQUE(source_id, stable_id)
);
CREATE INDEX IF NOT EXISTS idx_books_md5 ON books(md5);

CREATE TABLE IF NOT EXISTS tocs (
  book_key   TEXT PRIMARY KEY,
  source_id  TEXT NOT NULL,
  fetched_at INTEGER NOT NULL,
  chapters   TEXT NOT NULL,
  raw        TEXT
);

CREATE TABLE IF NOT EXISTS opens (
  path        TEXT PRIMARY KEY,
  book_key    TEXT NOT NULL,
  source_id   TEXT NOT NULL,
  stable_id   TEXT NOT NULL,
  chapter_idx INTEGER,
  last_open   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS http (
  key       TEXT PRIMARY KEY,
  value     TEXT NOT NULL,
  expires   INTEGER NOT NULL,
  source_id TEXT
);

CREATE TABLE IF NOT EXISTS pending_progress (
  source_id TEXT NOT NULL,
  stable_id TEXT NOT NULL,
  fraction REAL NOT NULL,
  chapter_idx INTEGER,
  chapter_fraction REAL,
  locator TEXT,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (source_id, stable_id)
);
]])
end

--- 打开（或复用）全局 SQLite 连接并确保 schema。
--- 仅 Task 子进程可调用。
---@return userdata|nil, string|nil
function Base.open()
    local Task = require("utils.task")
    if not Task.inSubProcess() then
        error("book.db: open() only allowed inside Task subprocess", 2)
    end
    if conn then
        return conn
    end
    local c, err = openSqlite()
    if not c then
        logger.warn("book.db open failed", err)
        return nil, err
    end
    conn = c
    pcall(function()
        conn:exec("PRAGMA journal_mode=WAL;")
    end)
    ensureSchema()
    return conn
end

--- 关闭全局连接
---@return nil
function Base.close()
    if conn then
        pcall(function()
            conn:close()
        end)
        conn = nil
    end
end

--- 确保连接可用（未开则 Base.open）
---@return userdata|nil, string|nil
function Base.ensure()
    if conn then
        return conn
    end
    return Base.open()
end

return Base
