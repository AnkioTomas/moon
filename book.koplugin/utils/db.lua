--[[--
插件 SQLite（$DATA/.moon/book.sqlite3）

表：
  books            — BookRef + 展示元数据 + 统计 md5
  tocs             — 目录缓存
  opens            — 本地路径 → BookRef + chapter_idx
  http             — HTTP GET 响应缓存
  pending_progress — 待上传进度（一书一条）

不做 schema/legacy 迁移。首次 open 只 CREATE IF NOT EXISTS。

@module koplugin.book.utils.db
--]]

local logger = require("logger")
local JSON = require("json")
local md5 = require("ffi/sha2").md5
local Paths = require("utils.paths")

local Db = {}

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
---@return boolean|nil, any
local function exec(sql)
    if not conn then
        return nil
    end
    local ok, err = pcall(function()
        conn:exec(sql)
    end)
    if not ok then
        logger.warn("book.db exec failed", err, sql and sql:sub(1, 120))
        return nil, err
    end
    return true
end

--- 执行并取一行多列（失败返回 nil）
---@param sql string
---@return any ...
local function rowexec(sql)
    if not conn then
        return nil
    end
    local ok, a, b, c, d, e, f, g, h, i, j, k, l, m, n = pcall(function()
        return conn:rowexec(sql)
    end)
    if not ok then
        logger.warn("book.db rowexec failed", a, sql and sql:sub(1, 120))
        return nil
    end
    return a, b, c, d, e, f, g, h, i, j, k, l, m, n
end

--- 值转 SQL 字面量（NULL / 数字 / 布尔 / 转义字符串）
---@param v any
---@return string
local function sqlQuote(v)
    if v == nil then
        return "NULL"
    end
    if type(v) == "number" then
        if v ~= v then
            return "NULL"
        end
        return tostring(v)
    end
    if type(v) == "boolean" then
        return v and "1" or "0"
    end
    return "'" .. tostring(v):gsub("'", "''") .. "'"
end

--- favorite 字段写入 DB 的字符串形式
---@param v any
---@return string|nil
local function favoriteToDb(v)
    if v == nil then
        return nil
    end
    if type(v) == "string" then
        return v
    end
    if type(v) == "number" or type(v) == "boolean" then
        return tostring(v)
    end
    local ok, encoded = pcall(JSON.encode, v)
    if ok and encoded then
        return encoded
    end
    return tostring(v)
end

--- 校验并消毒 source_id；非法返回 nil
---@param source_id string
---@return string|nil
local function requireSourceId(source_id)
    if type(source_id) ~= "string" or source_id == "" then
        return nil
    end
    return Paths.sanitizeSourceId(source_id)
end

--- 由 source_id + stable_id 生成 book_key（md5）
---@param source_id string
---@param stable_id string
---@return string|nil
local function bookKeyFor(source_id, stable_id)
    if type(stable_id) ~= "string" or stable_id == "" then
        return nil
    end
    source_id = requireSourceId(source_id)
    if not source_id then
        return nil
    end
    return md5(source_id .. ":" .. stable_id)
end

--- 首次打开时 CREATE IF NOT EXISTS 全表
---@return nil
local function ensureSchema()
    exec([[
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

--- 打开（或复用）全局 SQLite 连接并确保 schema
---@return userdata|nil, string|nil
function Db.open()
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
function Db.close()
    if conn then
        pcall(function()
            conn:close()
        end)
        conn = nil
    end
end

--- 确保连接可用（未开则 Db.open）
---@return userdata|nil, string|nil
local function ensure()
    if conn then
        return conn
    end
    return Db.open()
end

--- 插入或更新 books 行
---@param row table
---@return boolean
function Db.upsertBook(row)
    if type(row) ~= "table" then
        return false
    end
    ensure()
    if not conn then
        return false
    end
    local source_id = requireSourceId(row.source_id)
    local stable_id = row.stable_id or row.filename
    if type(stable_id) == "number" then
        stable_id = tostring(stable_id)
    end
    if not source_id or type(stable_id) ~= "string" or stable_id == "" then
        return false
    end
    local book_key = row.book_key
    if type(book_key) ~= "string" or book_key == "" then
        book_key = bookKeyFor(source_id, stable_id)
    end
    if not book_key then
        return false
    end
    local filename = row.filename or stable_id
    if filename ~= nil then
        filename = tostring(filename)
    end
    local sql = string.format(
        [[INSERT INTO books (
            book_key, source_id, stable_id, filename, md5, title, authors,
            percent, category, favorite, series, intro, fetched_at
          ) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
          ON CONFLICT(book_key) DO UPDATE SET
            source_id=excluded.source_id,
            stable_id=excluded.stable_id,
            filename=COALESCE(excluded.filename, books.filename),
            md5=COALESCE(excluded.md5, books.md5),
            title=excluded.title,
            authors=excluded.authors,
            percent=excluded.percent,
            category=excluded.category,
            favorite=excluded.favorite,
            series=excluded.series,
            intro=excluded.intro,
            fetched_at=excluded.fetched_at;]],
        sqlQuote(book_key),
        sqlQuote(source_id),
        sqlQuote(stable_id),
        sqlQuote(filename),
        sqlQuote(row.md5),
        sqlQuote(row.title),
        sqlQuote(row.authors),
        sqlQuote(tonumber(row.percent) or 0),
        sqlQuote(row.category),
        sqlQuote(favoriteToDb(row.favorite)),
        sqlQuote(row.series),
        sqlQuote(row.intro),
        sqlQuote(tonumber(row.fetched_at) or os.time())
    )
    return exec(sql) ~= nil
end

--- 按 book_key 取 books 行
---@param book_key string
---@return table|nil
function Db.getBook(book_key)
    if type(book_key) ~= "string" or book_key == "" then
        return nil
    end
    ensure()
    local book_key_r, source_id, stable_id, filename, digest, title, authors, percent, category, favorite, series, intro, fetched_at =
        rowexec(string.format(
            [[SELECT book_key, source_id, stable_id, filename, md5, title, authors,
                     percent, category, favorite, series, intro, fetched_at
              FROM books WHERE book_key=%s LIMIT 1;]],
            sqlQuote(book_key)
        ))
    if not book_key_r then
        return nil
    end
    return {
        book_key = book_key_r,
        source_id = source_id,
        stable_id = stable_id,
        filename = filename,
        md5 = digest,
        title = title,
        authors = authors,
        percent = tonumber(percent) or 0,
        category = category,
        favorite = favorite,
        series = series,
        intro = intro,
        fetched_at = tonumber(fetched_at) or 0,
    }
end

--- 按 filename/stable_id 写入或更新 md5
---@param filename string
---@param digest string
---@param filename_out string|nil
---@param source_id string
---@return boolean
function Db.setBookMd5(filename, digest, filename_out, source_id)
    if type(digest) ~= "string" or digest == "" then
        return false
    end
    if type(filename) ~= "string" or filename == "" then
        return false
    end
    source_id = requireSourceId(source_id)
    if not source_id then
        return false
    end
    ensure()
    if not conn then
        return false
    end
    filename_out = filename_out or filename
    local existing = rowexec(string.format(
        [[SELECT book_key FROM books WHERE filename=%s OR stable_id=%s LIMIT 1;]],
        sqlQuote(filename),
        sqlQuote(filename)
    ))
    if existing then
        return exec(string.format(
            [[UPDATE books SET md5=%s, filename=%s WHERE book_key=%s;]],
            sqlQuote(digest),
            sqlQuote(filename_out),
            sqlQuote(existing)
        )) ~= nil
    end
    return Db.upsertBook({
        book_key = bookKeyFor(source_id, filename),
        source_id = source_id,
        stable_id = filename,
        filename = filename_out,
        md5 = digest,
        fetched_at = 0,
    })
end

--- 按 book_key 更新 md5（可选同步 filename）
---@param book_key string
---@param digest string
---@param filename string|nil
---@return boolean
function Db.setBookMd5ByKey(book_key, digest, filename)
    if type(book_key) ~= "string" or book_key == "" then
        return false
    end
    if type(digest) ~= "string" or digest == "" then
        return false
    end
    ensure()
    local sets = string.format("md5=%s", sqlQuote(digest))
    if type(filename) == "string" and filename ~= "" then
        sets = sets .. string.format(", filename=%s", sqlQuote(filename))
    end
    local n = rowexec(string.format([[SELECT 1 FROM books WHERE book_key=%s LIMIT 1;]], sqlQuote(book_key)))
    if n then
        return exec(string.format([[UPDATE books SET %s WHERE book_key=%s;]], sets, sqlQuote(book_key))) ~= nil
    end
    return false
end

--- 全部 md5 → filename 映射
---@return table<string, string>
function Db.md5Map()
    ensure()
    if not conn then
        return {}
    end
    local result, nrows = conn:exec([[
SELECT md5, filename FROM books
WHERE md5 IS NOT NULL AND md5 != '' AND filename IS NOT NULL AND filename != '';
]])
    local map = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            local digest = result[1][i]
            local filename = result[2][i]
            if type(digest) == "string" and digest ~= "" and type(filename) == "string" and filename ~= "" then
                map[digest] = filename
            end
        end
    end
    return map
end

--- 按 md5 查 filename
---@param digest string
---@return string|nil
function Db.filenameByMd5(digest)
    if type(digest) ~= "string" or digest == "" then
        return nil
    end
    ensure()
    local filename = rowexec(string.format(
        [[SELECT filename FROM books WHERE md5=%s LIMIT 1;]],
        sqlQuote(digest)
    ))
    if type(filename) == "string" and filename ~= "" then
        return filename
    end
    return nil
end

--- 清空全部书籍展示元数据（保留键与 md5）
---@return boolean
function Db.stripBookMeta()
    ensure()
    return exec([[
UPDATE books SET
  title=NULL, authors=NULL, percent=0, category=NULL,
  favorite=NULL, series=NULL, intro=NULL, fetched_at=0;
]]) ~= nil
end

--- 清空 fetched_at 早于 before_ts 的书籍展示元数据
---@param before_ts number
---@return boolean
function Db.expireBooksBefore(before_ts)
    before_ts = tonumber(before_ts) or 0
    ensure()
    return exec(string.format([[
UPDATE books SET
  title=NULL, authors=NULL, percent=0, category=NULL,
  favorite=NULL, series=NULL, intro=NULL, fetched_at=0
WHERE fetched_at > 0 AND fetched_at < %d;
]], before_ts)) ~= nil
end

--- 写入/更新目录缓存
---@param book_key string
---@param source_id string
---@param toc { chapters: table, raw: any, fetched_at: number|nil }
---@return boolean
function Db.putToc(book_key, source_id, toc)
    if type(book_key) ~= "string" or book_key == "" or type(toc) ~= "table" then
        return false
    end
    source_id = requireSourceId(source_id)
    if not source_id then
        return false
    end
    ensure()
    local chapters = toc.chapters or toc
    local ok_enc, chapters_json = pcall(JSON.encode, chapters)
    if not ok_enc or not chapters_json then
        logger.warn("book.db putToc encode chapters failed", book_key)
        return false
    end
    local raw_json = nil
    if toc.raw ~= nil then
        local ok_r, encoded = pcall(JSON.encode, toc.raw)
        if ok_r then
            raw_json = encoded
        end
    end
    local sql = string.format(
        [[INSERT INTO tocs (book_key, source_id, fetched_at, chapters, raw)
          VALUES (%s,%s,%s,%s,%s)
          ON CONFLICT(book_key) DO UPDATE SET
            source_id=excluded.source_id,
            fetched_at=excluded.fetched_at,
            chapters=excluded.chapters,
            raw=excluded.raw;]],
        sqlQuote(book_key),
        sqlQuote(source_id),
        sqlQuote(tonumber(toc.fetched_at) or os.time()),
        sqlQuote(chapters_json),
        sqlQuote(raw_json)
    )
    return exec(sql) ~= nil
end

--- 按 book_key 取目录缓存
---@param book_key string
---@return table|nil
function Db.getToc(book_key)
    if type(book_key) ~= "string" or book_key == "" then
        return nil
    end
    ensure()
    local bk, source_id, fetched_at, chapters_json, raw_json = rowexec(string.format(
        [[SELECT book_key, source_id, fetched_at, chapters, raw FROM tocs WHERE book_key=%s LIMIT 1;]],
        sqlQuote(book_key)
    ))
    if not bk then
        return nil
    end
    local chapters = {}
    if type(chapters_json) == "string" and chapters_json ~= "" then
        local ok, decoded = pcall(JSON.decode, chapters_json)
        if ok and type(decoded) == "table" then
            chapters = decoded
        end
    end
    local raw = nil
    if type(raw_json) == "string" and raw_json ~= "" then
        local ok, decoded = pcall(JSON.decode, raw_json)
        if ok then
            raw = decoded
        end
    end
    return {
        book_key = bk,
        source_id = source_id,
        fetched_at = tonumber(fetched_at) or 0,
        chapters = chapters,
        raw = raw,
    }
end

--- 删除一条目录缓存
---@param book_key string
---@return boolean
function Db.deleteToc(book_key)
    if type(book_key) ~= "string" or book_key == "" then
        return false
    end
    ensure()
    return exec(string.format([[DELETE FROM tocs WHERE book_key=%s;]], sqlQuote(book_key))) ~= nil
end

--- 删除过期目录缓存
---@param before_ts number
---@return boolean
function Db.deleteExpiredTocs(before_ts)
    before_ts = tonumber(before_ts) or 0
    ensure()
    return exec(string.format([[DELETE FROM tocs WHERE fetched_at < %d;]], before_ts)) ~= nil
end

--- 清空全部目录缓存
---@return boolean
function Db.clearTocs()
    ensure()
    return exec([[DELETE FROM tocs;]]) ~= nil
end

--- 插入或更新本地打开记录
---@param path string
---@param row { book_key: string, source_id: string, stable_id: string, chapter_idx: number|nil, last_open: number|nil }
---@return boolean
function Db.upsertOpen(path, row)
    if type(path) ~= "string" or path == "" or type(row) ~= "table" then
        return false
    end
    if not row.book_key or not row.source_id or not row.stable_id then
        return false
    end
    local source_id = requireSourceId(row.source_id)
    if not source_id then
        return false
    end
    ensure()
    local sql = string.format(
        [[INSERT INTO opens (path, book_key, source_id, stable_id, chapter_idx, last_open)
          VALUES (%s,%s,%s,%s,%s,%s)
          ON CONFLICT(path) DO UPDATE SET
            book_key=excluded.book_key,
            source_id=excluded.source_id,
            stable_id=excluded.stable_id,
            chapter_idx=excluded.chapter_idx,
            last_open=excluded.last_open;]],
        sqlQuote(path),
        sqlQuote(tostring(row.book_key)),
        sqlQuote(source_id),
        sqlQuote(tostring(row.stable_id)),
        sqlQuote(row.chapter_idx),
        sqlQuote(tonumber(row.last_open) or os.time())
    )
    return exec(sql) ~= nil
end

--- 按本地路径取打开记录
---@param path string
---@return table|nil
function Db.getOpen(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    ensure()
    local p, book_key, source_id, stable_id, chapter_idx, last_open = rowexec(string.format(
        [[SELECT path, book_key, source_id, stable_id, chapter_idx, last_open FROM opens WHERE path=%s LIMIT 1;]],
        sqlQuote(path)
    ))
    if not p then
        return nil
    end
    return {
        path = p,
        book_key = book_key,
        source_id = source_id,
        stable_id = stable_id,
        chapter_idx = chapter_idx ~= nil and tonumber(chapter_idx) or nil,
        last_open = tonumber(last_open) or 0,
    }
end

--- 全部打开记录（path → row）
---@return table<string, table>
function Db.allOpens()
    ensure()
    if not conn then
        return {}
    end
    local result, nrows = conn:exec([[SELECT path, book_key, source_id, stable_id, chapter_idx, last_open FROM opens;]])
    local map = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            local path = result[1][i]
            if type(path) == "string" then
                map[path] = {
                    book_key = result[2][i],
                    source_id = result[3][i],
                    stable_id = result[4][i],
                    chapter_idx = result[5][i] ~= nil and tonumber(result[5][i]) or nil,
                    last_open = tonumber(result[6][i]) or 0,
                }
            end
        end
    end
    return map
end

--- 删除一条打开记录
---@param path string
---@return boolean
function Db.deleteOpen(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    ensure()
    return exec(string.format([[DELETE FROM opens WHERE path=%s;]], sqlQuote(path))) ~= nil
end

--- 清空全部打开记录
---@return boolean
function Db.clearOpens()
    ensure()
    return exec([[DELETE FROM opens;]]) ~= nil
end

--- 读 HTTP 缓存行（value_json, expires）
---@param key string
---@return string|nil, number|nil
function Db.httpGet(key)
    if type(key) ~= "string" or key == "" then
        return nil
    end
    ensure()
    local value, expires = rowexec(string.format(
        [[SELECT value, expires FROM http WHERE key=%s LIMIT 1;]],
        sqlQuote(key)
    ))
    if type(value) ~= "string" then
        return nil
    end
    return value, tonumber(expires) or 0
end

--- 写 HTTP 缓存行
---@param key string
---@param value_json string
---@param expires number
---@param source_id string|nil
---@return boolean
function Db.httpSet(key, value_json, expires, source_id)
    if type(key) ~= "string" or key == "" or type(value_json) ~= "string" then
        return false
    end
    ensure()
    local sql = string.format(
        [[INSERT INTO http (key, value, expires, source_id) VALUES (%s,%s,%s,%s)
          ON CONFLICT(key) DO UPDATE SET
            value=excluded.value,
            expires=excluded.expires,
            source_id=COALESCE(excluded.source_id, http.source_id);]],
        sqlQuote(key),
        sqlQuote(value_json),
        sqlQuote(tonumber(expires) or 0),
        sqlQuote(source_id)
    )
    return exec(sql) ~= nil
end

--- 删除一条 HTTP 缓存
---@param key string
---@return boolean
function Db.httpDelete(key)
    if type(key) ~= "string" or key == "" then
        return false
    end
    ensure()
    return exec(string.format([[DELETE FROM http WHERE key=%s;]], sqlQuote(key))) ~= nil
end

--- 清空 HTTP 缓存；有子串则只删 key 含该子串的行
---@param url_substr string|nil
---@return boolean
function Db.httpClear(url_substr)
    ensure()
    if type(url_substr) ~= "string" or url_substr == "" then
        return exec([[DELETE FROM http;]]) ~= nil
    end
    local pat = url_substr:gsub("([%%_])", "%%%1")
    return exec(string.format([[DELETE FROM http WHERE key LIKE %s;]], sqlQuote("%" .. pat .. "%"))) ~= nil
end

--- 删除已过期的 HTTP 缓存行
---@param now_ts number|nil
---@return boolean
function Db.httpDeleteExpired(now_ts)
    now_ts = tonumber(now_ts) or os.time()
    ensure()
    return exec(string.format([[DELETE FROM http WHERE expires <= %d;]], now_ts)) ~= nil
end

--- 插入或更新待上传进度
---@param source_id string
---@param stable_id string
---@param pos ProgressPosition
---@return boolean
function Db.upsertPendingProgress(source_id, stable_id, pos)
    source_id = requireSourceId(source_id)
    if not source_id or type(stable_id) ~= "string" or stable_id == "" or type(pos) ~= "table" then
        return false
    end
    local frac = tonumber(pos.fraction)
    if not frac then
        return false
    end
    ensure()
    local sql = string.format(
        [[INSERT INTO pending_progress
            (source_id, stable_id, fraction, chapter_idx, chapter_fraction, locator, updated_at)
          VALUES (%s,%s,%s,%s,%s,%s,%s)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            fraction=excluded.fraction,
            chapter_idx=excluded.chapter_idx,
            chapter_fraction=excluded.chapter_fraction,
            locator=excluded.locator,
            updated_at=excluded.updated_at;]],
        sqlQuote(source_id),
        sqlQuote(stable_id),
        sqlQuote(frac),
        sqlQuote(pos.chapter_idx),
        sqlQuote(pos.chapter_fraction),
        sqlQuote(pos.locator),
        sqlQuote(os.time())
    )
    return exec(sql) ~= nil
end

--- 列出待上传进度（可按 source_id 过滤）
---@param source_id string|nil
---@return table[]
function Db.allPendingProgress(source_id)
    ensure()
    if not conn then
        return {}
    end
    local sql
    if type(source_id) == "string" and source_id ~= "" then
        sql = string.format(
            [[SELECT source_id, stable_id, fraction, chapter_idx, chapter_fraction, locator, updated_at
              FROM pending_progress WHERE source_id=%s ORDER BY updated_at ASC;]],
            sqlQuote(source_id)
        )
    else
        sql = [[SELECT source_id, stable_id, fraction, chapter_idx, chapter_fraction, locator, updated_at
                FROM pending_progress ORDER BY updated_at ASC;]]
    end
    local result, nrows = conn:exec(sql)
    local out = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            out[#out + 1] = {
                source_id = result[1][i],
                stable_id = result[2][i],
                fraction = tonumber(result[3][i]) or 0,
                chapter_idx = result[4][i] ~= nil and tonumber(result[4][i]) or nil,
                chapter_fraction = result[5][i] ~= nil and tonumber(result[5][i]) or nil,
                locator = result[6][i],
                updated_at = tonumber(result[7][i]) or 0,
            }
        end
    end
    return out
end

--- 删除一条待上传进度
---@param source_id string
---@param stable_id string
---@return boolean
function Db.deletePendingProgress(source_id, stable_id)
    source_id = requireSourceId(source_id)
    if not source_id or type(stable_id) ~= "string" or stable_id == "" then
        return false
    end
    ensure()
    return exec(string.format(
        [[DELETE FROM pending_progress WHERE source_id=%s AND stable_id=%s;]],
        sqlQuote(source_id),
        sqlQuote(stable_id)
    )) ~= nil
end

return Db
