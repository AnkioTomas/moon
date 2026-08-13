--[[--
插件 SQLite（$DATA/.moon/book.sqlite3）

表：
  books  — 书元数据；含 filename、md5（一书一 md5）。清缓存只剥 title 等展示字段，保留身份/filename/md5
  tocs   — 目录缓存；chapters 整包 JSON
  opens  — 本地 epub 路径 → book_key/stable_id/chapter_idx（进度同步、阅读面板、过期清理）
  http   — HTTP GET 响应缓存（原进程内 http.cache）

驱动：KOReader 自带 lua-ljsqlite3。首次 open 建表并幂等迁移旧 JSON meta/toc、filemap、stats_md5_map。

@module koplugin.book.utils.db
--]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local JSON = require("json")
local md5 = require("ffi/sha2").md5
local Paths = require("utils.paths")

local Db = {}

local SCHEMA_VERSION = 1
local conn = nil
local migrated = false

--- 库文件绝对路径（$DATA/.moon/book.sqlite3）
---@return string
local function dbPath()
    return Paths.dbPath()
end

--- 打开 SQLite 连接；失败返回 nil, err
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

--- 执行写 SQL；无连接或抛错返回 nil
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

--- 查单行：多列按返回值展开；无行或失败返回 nil
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

--- 把 Lua 值编成 SQL 字面量（防注入用单引号加倍；nil→NULL）
---@param v any
---@return string
local function sqlQuote(v)
    if v == nil then
        return "NULL"
    end
    if type(v) == "number" then
        if v ~= v then -- nan
            return "NULL"
        end
        return tostring(v)
    end
    if type(v) == "boolean" then
        return v and "1" or "0"
    end
    local s = tostring(v):gsub("'", "''")
    return "'" .. s .. "'"
end

--- favorite 可能是任意类型，落库统一成 TEXT
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

--- 建四表 + md5 索引，并写入 user_version
local function ensureSchema()
    exec([[
CREATE TABLE IF NOT EXISTS books (
  book_key   TEXT PRIMARY KEY,
  source_id  TEXT NOT NULL,
  stable_id  TEXT NOT NULL,
  filename   TEXT,
  md5        TEXT,
  id         TEXT,
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
  stable_id   TEXT,
  chapter_idx INTEGER,
  last_open   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS http (
  key     TEXT PRIMARY KEY,
  value   TEXT NOT NULL,
  expires INTEGER NOT NULL
);
]])
    exec(string.format("PRAGMA user_version=%d;", SCHEMA_VERSION))
end

--- 读磁盘 JSON 文件；坏数据返回 nil
---@param path string
---@return table|nil
local function readJsonFile(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then
        return nil
    end
    local ok, data = pcall(JSON.decode, raw)
    if ok and type(data) == "table" then
        return data
    end
    return nil
end

--- book_key = md5(sourceId .. ":" .. stableId)
---@param source_id string|nil
---@param stable_id string|nil
---@return string|nil
local function bookKeyFor(source_id, stable_id)
    if type(stable_id) ~= "string" or stable_id == "" then
        return nil
    end
    source_id = Paths.sanitizeSourceId(source_id or "moon")
    return md5(source_id .. ":" .. stable_id)
end

--- 一次性迁入旧存储（幂等；进程内只跑一次）
--- 1) cache/<source>/meta|toc 下 JSON → books/tocs，成功后删文件
--- 2) G_reader_settings book_plugin_filemap_v2 → opens，并清空该键
--- 3) common.lua stats_md5_map → books.md5/filename，并删掉该字段
local function migrateLegacy()
    if migrated or not conn then
        return
    end
    migrated = true

    local cache_root = Paths.cacheDir()
    if lfs.attributes(cache_root, "mode") == "directory" then
        for source_name in lfs.dir(cache_root) do
            if source_name ~= "." and source_name ~= ".." then
                local source_dir = cache_root .. "/" .. source_name
                if lfs.attributes(source_dir, "mode") == "directory" then
                    local meta_dir = source_dir .. "/meta"
                    if lfs.attributes(meta_dir, "mode") == "directory" then
                        for name in lfs.dir(meta_dir) do
                            if name ~= "." and name ~= ".." then
                                local path = meta_dir .. "/" .. name
                                if lfs.attributes(path, "mode") == "file" then
                                    local data = readJsonFile(path)
                                    if data then
                                        local stable = data.stable_id or data.id or data.filename or data.bookId
                                        if stable ~= nil then
                                            stable = tostring(stable)
                                        end
                                        local filename = data.filename or stable
                                        Db.upsertBook({
                                            book_key = data.book_key or name,
                                            source_id = source_name,
                                            stable_id = stable or name,
                                            filename = filename and tostring(filename) or nil,
                                            md5 = data.md5,
                                            id = data.id and tostring(data.id) or stable,
                                            title = data.title or data.bookName,
                                            authors = data.authors or data.author,
                                            percent = tonumber(data.percent or data.progressPercent or data.progress) or 0,
                                            category = data.category,
                                            favorite = data.favorite,
                                            series = data.series,
                                            intro = data.intro or data.description,
                                            fetched_at = tonumber(data.fetched_at) or 0,
                                        })
                                        pcall(os.remove, path)
                                    end
                                end
                            end
                        end
                    end
                    local toc_dir = source_dir .. "/toc"
                    if lfs.attributes(toc_dir, "mode") == "directory" then
                        for name in lfs.dir(toc_dir) do
                            if name ~= "." and name ~= ".." then
                                local path = toc_dir .. "/" .. name
                                if lfs.attributes(path, "mode") == "file" then
                                    local data = readJsonFile(path)
                                    if data then
                                        Db.putToc(data.book_key or name, source_name, {
                                            chapters = data.chapters or data,
                                            raw = data.raw,
                                            fetched_at = tonumber(data.fetched_at) or os.time(),
                                        })
                                        pcall(os.remove, path)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if G_reader_settings then
        local FILEMAP_KEY = "book_plugin_filemap_v2"
        local map = G_reader_settings:readSetting(FILEMAP_KEY)
        if type(map) == "table" then
            for path, v in pairs(map) do
                if type(path) == "string" and type(v) == "table" and v.book_key then
                    Db.upsertOpen(path, {
                        book_key = tostring(v.book_key),
                        stable_id = v.stable_id or v.filename,
                        chapter_idx = v.chapter_idx,
                        last_open = tonumber(v.last_open) or os.time(),
                    })
                end
            end
            G_reader_settings:saveSetting(FILEMAP_KEY, {})
        end
        G_reader_settings:saveSetting("book_plugin_meta_v2", {})
    end

    local ok_s, Settings = pcall(require, "utils.settings")
    if ok_s and Settings and Settings.get then
        local s = Settings.get()
        local md5_map = type(s.stats_md5_map) == "table" and s.stats_md5_map or nil
        if md5_map and next(md5_map) then
            local source_id = "moon"
            if type(s.active_source) == "string" and s.active_source ~= "" then
                source_id = s.active_source
            end
            for digest, filename in pairs(md5_map) do
                if type(digest) == "string" and digest ~= "" and type(filename) == "string" and filename ~= "" then
                    Db.setBookMd5(filename, digest, filename, source_id)
                end
            end
            s.stats_md5_map = nil
            Settings.save(s)
        end
    end

    logger.info("book.db legacy migrate done")
end

--- 打开库（单例）：建表 + 旧数据迁移。已打开则直接返回连接
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
    migrateLegacy()
    return conn
end

--- 关闭连接；下次 API 调用会重新 open
function Db.close()
    if conn then
        pcall(function()
            conn:close()
        end)
        conn = nil
        migrated = false
    end
end

--- 确保连接可用（懒打开）
---@return userdata|nil, string|nil
local function ensure()
    if conn then
        return conn
    end
    return Db.open()
end

--- 插入或更新一本书。
--- meta 字段按传入值覆盖；filename/md5 用 COALESCE，避免纯 meta 写入冲掉已有统计映射。
---@param row table book_key/source_id/stable_id 及可选 meta、filename、md5、fetched_at
---@return boolean
function Db.upsertBook(row)
    if type(row) ~= "table" then
        return false
    end
    ensure()
    if not conn then
        return false
    end
    local book_key = row.book_key
    local source_id = Paths.sanitizeSourceId(row.source_id or "moon")
    local stable_id = row.stable_id or row.id or row.filename
    if type(stable_id) == "number" then
        stable_id = tostring(stable_id)
    end
    if type(stable_id) ~= "string" or stable_id == "" then
        return false
    end
    if type(book_key) ~= "string" or book_key == "" then
        book_key = bookKeyFor(source_id, stable_id)
    end
    if not book_key then
        return false
    end
    local filename = row.filename or stable_id
    local id = row.id or stable_id
    if id ~= nil then
        id = tostring(id)
    end
    if filename ~= nil then
        filename = tostring(filename)
    end
    local sql = string.format(
        [[INSERT INTO books (
            book_key, source_id, stable_id, filename, md5, id, title, authors,
            percent, category, favorite, series, intro, fetched_at
          ) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
          ON CONFLICT(book_key) DO UPDATE SET
            source_id=excluded.source_id,
            stable_id=excluded.stable_id,
            filename=COALESCE(excluded.filename, books.filename),
            md5=COALESCE(excluded.md5, books.md5),
            id=excluded.id,
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
        sqlQuote(id),
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

--- 按 book_key 取整行；不存在返回 nil（不做 TTL 判断，由 Cache 层处理）
---@param book_key string
---@return table|nil
function Db.getBook(book_key)
    if type(book_key) ~= "string" or book_key == "" then
        return nil
    end
    ensure()
    local book_key_r, source_id, stable_id, filename, digest, id, title, authors, percent, category, favorite, series, intro, fetched_at =
        rowexec(string.format(
            [[SELECT book_key, source_id, stable_id, filename, md5, id, title, authors,
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
        id = id,
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

--- 按远端 filename（或 stable_id）写入 md5：一书一值，覆盖写。
--- 无对应行则插最小行（fetched_at=0，不算有效 meta 缓存）。
---@param filename string 查找键，兼默认 stable_id
---@param digest string 内容 partialMD5
---@param filename_out string|nil 写入的 filename 列；默认同 filename
---@param source_id string|nil 新建行时用；默认 moon
---@return boolean
function Db.setBookMd5(filename, digest, filename_out, source_id)
    if type(digest) ~= "string" or digest == "" then
        return false
    end
    if type(filename) ~= "string" or filename == "" then
        return false
    end
    ensure()
    if not conn then
        return false
    end
    source_id = Paths.sanitizeSourceId(source_id or "moon")
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
    local book_key = bookKeyFor(source_id, filename)
    return Db.upsertBook({
        book_key = book_key,
        source_id = source_id,
        stable_id = filename,
        filename = filename_out,
        md5 = digest,
        id = filename,
        fetched_at = 0,
    })
end

--- 按 book_key 写 md5（及可选 filename）。行不存在且带 filename 时回退 setBookMd5
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
    if type(filename) == "string" and filename ~= "" then
        return Db.setBookMd5(filename, digest, filename)
    end
    return false
end

--- 统计上报用：md5 → filename 全表映射
---@return table<string, string>
function Db.md5Map()
    ensure()
    if not conn then
        return {}
    end
    local result, nrows = conn:exec([[SELECT md5, filename FROM books WHERE md5 IS NOT NULL AND md5 != '' AND filename IS NOT NULL AND filename != '';]])
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

--- 单个 digest 反查远端 filename
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

--- 清缓存：剥掉展示用 meta，保留 book_key/source_id/stable_id/filename/md5
---@return boolean
function Db.stripBookMeta()
    ensure()
    return exec([[
UPDATE books SET
  id=COALESCE(stable_id, id),
  title=NULL,
  authors=NULL,
  percent=0,
  category=NULL,
  favorite=NULL,
  series=NULL,
  intro=NULL,
  fetched_at=0;
]]) ~= nil
end

--- TTL 过期：fetched_at 早于 before_ts 的行剥 meta（不删行，md5/filename 保留）
---@param before_ts number unix 秒
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

--- 写入/覆盖某书目录；chapters 与可选 raw 存 JSON 文本
---@param book_key string
---@param source_id string|nil
---@param toc { chapters: table, raw: any, fetched_at: number|nil }
---@return boolean
function Db.putToc(book_key, source_id, toc)
    if type(book_key) ~= "string" or book_key == "" or type(toc) ~= "table" then
        return false
    end
    ensure()
    source_id = Paths.sanitizeSourceId(source_id or "moon")
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

--- 读取目录；chapters/raw 已 JSON.decode。不做 TTL（由 Cache 判断）
---@param book_key string
---@return table|nil { book_key, source_id, fetched_at, chapters, raw }
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

--- 删除单本目录缓存
---@param book_key string
---@return boolean
function Db.deleteToc(book_key)
    if type(book_key) ~= "string" or book_key == "" then
        return false
    end
    ensure()
    return exec(string.format([[DELETE FROM tocs WHERE book_key=%s;]], sqlQuote(book_key))) ~= nil
end

--- 删除 fetched_at 早于 before_ts 的目录行
---@param before_ts number unix 秒
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

--- 记录「这个本地路径对应哪本书/哪一章」。打开或下载落盘时由 Cache.touch 调用。
--- 用途：进度同步、阅读面板、90 天未打开清理（看 last_open）
---@param path string 本地 epub 绝对路径
---@param row { book_key: string, stable_id: string|nil, chapter_idx: number|nil, last_open: number|nil }
---@return boolean
function Db.upsertOpen(path, row)
    if type(path) ~= "string" or path == "" or type(row) ~= "table" or not row.book_key then
        return false
    end
    ensure()
    local sql = string.format(
        [[INSERT INTO opens (path, book_key, stable_id, chapter_idx, last_open)
          VALUES (%s,%s,%s,%s,%s)
          ON CONFLICT(path) DO UPDATE SET
            book_key=excluded.book_key,
            stable_id=excluded.stable_id,
            chapter_idx=excluded.chapter_idx,
            last_open=excluded.last_open;]],
        sqlQuote(path),
        sqlQuote(tostring(row.book_key)),
        sqlQuote(row.stable_id),
        sqlQuote(row.chapter_idx),
        sqlQuote(tonumber(row.last_open) or os.time())
    )
    return exec(sql) ~= nil
end

--- 按本地路径查打开记录
---@param path string
---@return table|nil { path, book_key, stable_id, chapter_idx, last_open }
function Db.getOpen(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    ensure()
    local p, book_key, stable_id, chapter_idx, last_open = rowexec(string.format(
        [[SELECT path, book_key, stable_id, chapter_idx, last_open FROM opens WHERE path=%s LIMIT 1;]],
        sqlQuote(path)
    ))
    if not p then
        return nil
    end
    return {
        path = p,
        book_key = book_key,
        stable_id = stable_id,
        chapter_idx = chapter_idx ~= nil and tonumber(chapter_idx) or nil,
        last_open = tonumber(last_open) or 0,
    }
end

--- 全部打开记录：path → 行表（供 cleanupStale 扫 last_open）
---@return table<string, table>
function Db.allOpens()
    ensure()
    if not conn then
        return {}
    end
    local result, nrows = conn:exec([[SELECT path, book_key, stable_id, chapter_idx, last_open FROM opens;]])
    local map = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            local path = result[1][i]
            if type(path) == "string" then
                map[path] = {
                    book_key = result[2][i],
                    stable_id = result[3][i],
                    chapter_idx = result[4][i] ~= nil and tonumber(result[4][i]) or nil,
                    last_open = tonumber(result[5][i]) or 0,
                }
            end
        end
    end
    return map
end

--- 删除单条打开映射（文件已不存在时）
---@param path string
---@return boolean
function Db.deleteOpen(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    ensure()
    return exec(string.format([[DELETE FROM opens WHERE path=%s;]], sqlQuote(path))) ~= nil
end

--- 清空全部打开映射（Cache.clear 时）
---@return boolean
function Db.clearOpens()
    ensure()
    return exec([[DELETE FROM opens;]]) ~= nil
end

--- 读 HTTP 缓存原始 JSON 文本与过期时间；不做 TTL 删除（由 http.cache 决定）
---@param key string 如 "GET https://..."
---@return string|nil value_json
---@return number|nil expires
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

--- 写入 HTTP 缓存（value 已是 JSON 字符串；expires 为 unix 秒）
---@param key string
---@param value_json string
---@param expires number
---@return boolean
function Db.httpSet(key, value_json, expires)
    if type(key) ~= "string" or key == "" or type(value_json) ~= "string" then
        return false
    end
    ensure()
    local sql = string.format(
        [[INSERT INTO http (key, value, expires) VALUES (%s,%s,%s)
          ON CONFLICT(key) DO UPDATE SET value=excluded.value, expires=excluded.expires;]],
        sqlQuote(key),
        sqlQuote(value_json),
        sqlQuote(tonumber(expires) or 0)
    )
    return exec(sql) ~= nil
end

--- 删除单条 HTTP 缓存
---@param key string
---@return boolean
function Db.httpDelete(key)
    if type(key) ~= "string" or key == "" then
        return false
    end
    ensure()
    return exec(string.format([[DELETE FROM http WHERE key=%s;]], sqlQuote(key))) ~= nil
end

--- 清空 HTTP 缓存；传 url_substr 则只删 key 含该子串的行
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

--- 删除已过期的 HTTP 行
---@param now_ts number|nil 默认 os.time()
---@return boolean
function Db.httpDeleteExpired(now_ts)
    now_ts = tonumber(now_ts) or os.time()
    ensure()
    return exec(string.format([[DELETE FROM http WHERE expires <= %d;]], now_ts)) ~= nil
end

return Db
