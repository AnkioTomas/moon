--[[--
插件 SQLite 连接与通用原语（$DATA/.moon/book.sqlite3）。

表由 open → ensureSchema 创建并原地补列。数据库只允许向前迁移，
绝不因版本变化删除用户的书架、进度、笔记或统计。

使用 WAL 模式 + busy_timeout=5000，主/子进程均可安全访问。

@module koplugin.book.utils.db.base
--]]

local logger = require("logger")
local Paths = require("utils.paths")

local Base = {}

local conn = nil
local conn_is_subprocess_owned = false

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

local SCHEMA_VERSION = 4

---@param table_name string
---@param column_name string
---@return boolean
local function hasColumn(table_name, column_name)
    local columns, nrows = Base.query("PRAGMA table_info(" .. table_name .. ");")
    if not columns or not columns[2] then
        return false
    end
    for i = 1, nrows do
        if columns[2][i] == column_name then
            return true
        end
    end
    return false
end

--- 首次打开时 CREATE IF NOT EXISTS 全表
---@return nil
local function ensureSchema()
    Base.exec([[
CREATE TABLE IF NOT EXISTS books (
  source_id  TEXT NOT NULL,
  stable_id  TEXT NOT NULL,
  md5        TEXT,
  title      TEXT,
  authors    TEXT,
  percent    REAL DEFAULT 0,
  category   TEXT,
  favorite   TEXT,
  series     TEXT,
  intro      TEXT,
  fetched_at INTEGER NOT NULL DEFAULT 0,
  path        TEXT,
  last_open   INTEGER NOT NULL DEFAULT 0,
  last_chapter_idx INTEGER,
  in_library INTEGER NOT NULL DEFAULT 1,
  metadata_dirty INTEGER NOT NULL DEFAULT 0,
  metadata_updated_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source_id, stable_id)
);
CREATE INDEX IF NOT EXISTS idx_books_md5 ON books(source_id, md5);
CREATE INDEX IF NOT EXISTS idx_books_path ON books(path);
CREATE INDEX IF NOT EXISTS idx_books_library ON books(source_id, in_library, stable_id);

CREATE TABLE IF NOT EXISTS chapters (
  path        TEXT PRIMARY KEY,
  source_id   TEXT NOT NULL,
  stable_id   TEXT NOT NULL,
  chapter_idx INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS http (
  key       TEXT PRIMARY KEY,
  value     TEXT NOT NULL,
  expires   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS pending_progress (
  source_id TEXT NOT NULL,
  stable_id TEXT NOT NULL,
  fraction REAL NOT NULL,
  chapter_idx INTEGER,
  chapter_title TEXT,
  chapter_fraction REAL,
  page INTEGER,
  total_pages INTEGER,
  locator TEXT,
  updated_at INTEGER NOT NULL,
  sync_status INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source_id, stable_id)
);

CREATE TABLE IF NOT EXISTS reading_stats (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  source_id   TEXT NOT NULL,
  stable_id   TEXT NOT NULL,
  page        INTEGER NOT NULL DEFAULT 0,
  start_time  INTEGER NOT NULL,
  duration    INTEGER NOT NULL DEFAULT 0,
  total_pages INTEGER NOT NULL DEFAULT 0,
  sync_status INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_reading_stats_source ON reading_stats(source_id);

CREATE TABLE IF NOT EXISTS notes (
  source_id   TEXT NOT NULL,
  stable_id   TEXT NOT NULL,
  chapter_idx INTEGER NOT NULL DEFAULT 0,
  payload     TEXT NOT NULL,
  updated_at  INTEGER NOT NULL,
  sync_status INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source_id, stable_id, chapter_idx)
);

CREATE TABLE IF NOT EXISTS toc (
  source_id  TEXT NOT NULL,
  stable_id  TEXT NOT NULL,
  payload    TEXT NOT NULL,
  fetched_at INTEGER NOT NULL,
  PRIMARY KEY (source_id, stable_id)
);

CREATE TABLE IF NOT EXISTS ai_analysis (
  source_id   TEXT NOT NULL,
  stable_id   TEXT NOT NULL,
  chapter_idx INTEGER NOT NULL DEFAULT 0,
  context_key TEXT NOT NULL,
  page        INTEGER NOT NULL DEFAULT 0,
  payload     TEXT NOT NULL,
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (source_id, stable_id, chapter_idx, context_key)
);
CREATE INDEX IF NOT EXISTS idx_ai_analysis_book
  ON ai_analysis(source_id, stable_id, updated_at);

CREATE TABLE IF NOT EXISTS xray_entities (
  source_id    TEXT NOT NULL,
  stable_id    TEXT NOT NULL,
  kind         TEXT NOT NULL,
  name         TEXT NOT NULL,
  aliases_json TEXT NOT NULL DEFAULT '[]',
  payload_json TEXT NOT NULL DEFAULT '{}',
  updated_at   INTEGER NOT NULL,
  PRIMARY KEY (source_id, stable_id, kind, name)
);
CREATE INDEX IF NOT EXISTS idx_xray_entities_book
  ON xray_entities(source_id, stable_id, kind);

CREATE TABLE IF NOT EXISTS xray_timeline (
  source_id  TEXT NOT NULL,
  stable_id  TEXT NOT NULL,
  chapter    TEXT NOT NULL,
  event      TEXT NOT NULL,
  page       INTEGER NOT NULL DEFAULT 0,
  sort_idx   INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (source_id, stable_id, chapter)
);
CREATE INDEX IF NOT EXISTS idx_xray_timeline_book
  ON xray_timeline(source_id, stable_id, sort_idx);

CREATE TABLE IF NOT EXISTS xray_meta (
  source_id       TEXT NOT NULL,
  stable_id       TEXT NOT NULL,
  last_fetch_page INTEGER NOT NULL DEFAULT 0,
  book_type       TEXT,
  updated_at      INTEGER NOT NULL,
  PRIMARY KEY (source_id, stable_id)
);
]])
    if not hasColumn("books", "in_library") then
        Base.exec("ALTER TABLE books ADD COLUMN in_library INTEGER NOT NULL DEFAULT 1;")
    end
    if not hasColumn("books", "metadata_dirty") then
        Base.exec("ALTER TABLE books ADD COLUMN metadata_dirty INTEGER NOT NULL DEFAULT 0;")
    end
    if not hasColumn("books", "metadata_updated_at") then
        Base.exec("ALTER TABLE books ADD COLUMN metadata_updated_at INTEGER NOT NULL DEFAULT 0;")
    end
    Base.exec([[CREATE INDEX IF NOT EXISTS idx_books_library
        ON books(source_id, in_library, stable_id);]])
    if not hasColumn("pending_progress", "sync_status") then
        Base.exec("ALTER TABLE pending_progress ADD COLUMN sync_status INTEGER NOT NULL DEFAULT 0;")
    end
    if not hasColumn("pending_progress", "chapter_title") then
        Base.exec("ALTER TABLE pending_progress ADD COLUMN chapter_title TEXT;")
    end
    if not hasColumn("pending_progress", "page") then
        Base.exec("ALTER TABLE pending_progress ADD COLUMN page INTEGER;")
    end
    if not hasColumn("pending_progress", "total_pages") then
        Base.exec("ALTER TABLE pending_progress ADD COLUMN total_pages INTEGER;")
    end
    if not hasColumn("reading_stats", "sync_status") then
        Base.exec("ALTER TABLE reading_stats ADD COLUMN sync_status INTEGER NOT NULL DEFAULT 0;")
    end
    Base.exec([[DELETE FROM reading_stats WHERE id NOT IN (
        SELECT MIN(id) FROM reading_stats
        GROUP BY source_id, stable_id, page, start_time, duration, total_pages
    );]])
    Base.exec([[CREATE UNIQUE INDEX IF NOT EXISTS idx_reading_stats_identity
        ON reading_stats(source_id, stable_id, page, start_time, duration, total_pages);]])
    if not hasColumn("notes", "sync_status") then
        Base.exec("ALTER TABLE notes ADD COLUMN sync_status INTEGER NOT NULL DEFAULT 0;")
    end
    Base.exec("PRAGMA user_version=" .. SCHEMA_VERSION .. ";")
end

--- 打开（或复用）全局 SQLite 连接并确保 schema。
--- WAL 模式 + busy_timeout=5000。
--- 读操作可在主进程直接调用（WAL 读读安全）；写操作应走 utils.db.queue 串行化。
--- 子进程必须重新 open：fork 后继承的 conn 是父进程连接，跨进程使用会损坏 SQLite。
---@return userdata|nil, string|nil
function Base.open()
    -- fork 后子进程必须重新打开：conn 是父进程连接，不能跨进程使用
    -- conn_is_subprocess_owned 标记 conn 是否是当前子进程自己创建的
    local Task = require("utils.task")
    if Task.inSubProcess() and conn and not conn_is_subprocess_owned then
        Base.close()
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
    conn_is_subprocess_owned = Task.inSubProcess()
    pcall(function()
        conn:exec("PRAGMA journal_mode=WAL;")
        conn:exec("PRAGMA busy_timeout=5000;")
    end)
    local version = tonumber((Base.rowexec("PRAGMA user_version;"))) or 0
    if version > SCHEMA_VERSION then
        local version_err = "database schema is newer than this plugin: " .. tostring(version)
        logger.warn("book.db open failed", version_err)
        Base.close()
        return nil, version_err
    end
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
        conn_is_subprocess_owned = false
    end
end

--- 确保连接可用（未开则 Base.open）。
--- 读操作可在主进程直接调用；写操作应走 utils.db.queue 串行化。
---@return userdata|nil, string|nil
function Base.ensure()
    if conn then
        return conn
    end
    return Base.open()
end

return Base
