--[[--
books 表：身份 + 书架成员（软删）+ 展示元数据 + 目录/排版本地缓存。

列职责：
  身份：source_id + stable_id（PK）、md5、path、inserted_at（0=仅身份行）
  成员：deleted（0=在架有效，1=软删/非成员）；sync_status（0 待上传，1 已同步）
  展示：title/authors/category/series/intro/cover
  本地-only：reader_prefs、toc、toc_fetched_at、read_state
  进度真源在 pending_progress；本表不存 percent。

@module koplugin.book.db.book
--]]

--- 路径解析出的阅读身份（Store.identityFor / ensureIdentity 返回值）。
---@class BookIdentity
---@field source_id string 源标识（moon / wechat / jdread / local 等）
---@field stable_id string 源内稳定身份
---@field chapter_idx number|nil 章节文件时为章号；整本书为 nil
---@field book Book|nil books 表元数据行；刚登记/未入库时可能为内存行或 nil
---@field source BookSource|nil 属主源实例；仅 ensureIdentity（打开时）解析，identityFor 不挂
---@field cover string|nil 封面 URL（部分源直接挂在身份上）
---@field cover_url string|nil 封面 URL 别名

--- 对应表 books：身份列 + 展示元数据 + 软删成员 + sync_status。
---@class Book
---@field source_id string 源标识；与 stable_id 共同组成 PRIMARY KEY
---@field stable_id string 源内稳定身份；本地源即文件绝对路径
---@field md5 string|nil 内容 partialMD5；本地源用它识别文件改名/移动
---@field title string|nil 书名
---@field authors string|nil 作者
---@field percent number|nil 展示用进度 0..100（来自 pending_progress.fraction，非 books 列）
---@field chapter_idx integer|nil 展示用章节序号（来自 pending_progress，非 books 列）
---@field chapter_title string|nil 展示用章节标题（来自 pending_progress，非 books 列）
---@field page integer|nil 展示用页码（来自 pending_progress，非 books 列）
---@field total_pages integer|nil 展示用总页数（来自 pending_progress，非 books 列）
---@field category string|nil 分类 / 标签
---@field series string|nil 系列名
---@field intro string|nil 简介
---@field inserted_at integer|nil 本行首次写入时间；0 表示仅身份行；内存展示行可能没有
---@field path string|nil 本地文件路径；身份解析唯一入口
---@field deleted integer|nil 0=在架有效，1=软删/非成员
---@field sync_status integer|nil 0=待上传，1=已同步
---@field cover string|nil 封面 URL
---@field cover_url string|nil 封面 URL（部分源别名）
---@field cover_headers table|nil 封面请求头
---@field format string|nil 文件格式（epub/pdf 等，zlib 预览书）
---@field author string|nil 作者（部分源单数字段；展示优先 authors）
---@field fileSize number|nil 文件大小（字节，驼峰）
---@field filesize number|nil 文件大小（字节）
---@field file_size number|nil 文件大小（字节，蛇形）
---@field size number|nil 文件大小（字节，泛用）
---@field chapter table|nil 当前章元数据（阅读态）
---@field read_state integer|nil 0=未读且可自动标记，1=已读，2=用户强制未读
---@field reader_prefs string|nil 全书排版偏好 JSON（仅本地）
---@field toc string|nil 目录缓存 JSON（仅本地）
---@field toc_fetched_at integer|nil 目录缓存时间

--- 书籍详情（继承 Book 全部字段，含 intro）。
--- 详情页 / 悬浮菜单简介区使用；列表接口不必填 intro。
---@class BookDetail : Book

local Base = require("db.base")

local BookDB = {}

--- 创建 books 表及其常用索引。
--- 仅在 Base.open() 的一次性 schema 初始化阶段调用。
---@return boolean 成功返回 true，SQL 失败返回 false
function BookDB.ensureSchema()
    if not Base.exec([[
CREATE TABLE IF NOT EXISTS books (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL, md5 TEXT, title TEXT,
  authors TEXT, category TEXT, series TEXT, intro TEXT, cover TEXT,
  inserted_at INTEGER NOT NULL DEFAULT 0, path TEXT,
  deleted INTEGER NOT NULL DEFAULT 1, sync_status INTEGER NOT NULL DEFAULT 1,
  reader_prefs TEXT, toc TEXT, toc_fetched_at INTEGER NOT NULL DEFAULT 0,
  read_state INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source_id, stable_id)
);
]]) then return false end
    local columns, nrows = Base.query("PRAGMA table_info(books);")
    local present = {}
    local missing = {
        { "cover", "cover TEXT" },
        { "inserted_at", "inserted_at INTEGER NOT NULL DEFAULT 0" },
        { "deleted", "deleted INTEGER NOT NULL DEFAULT 1" },
        { "sync_status", "sync_status INTEGER NOT NULL DEFAULT 1" },
        { "reader_prefs", "reader_prefs TEXT" },
        { "toc", "toc TEXT" },
        { "toc_fetched_at", "toc_fetched_at INTEGER NOT NULL DEFAULT 0" },
        { "read_state", "read_state INTEGER NOT NULL DEFAULT 0" },
    }
    if columns then
        for i = 1, nrows do
            present[columns[2][i]] = true
        end
        for _, column in ipairs(missing) do
            if not present[column[1]]
                and not Base.exec("ALTER TABLE books ADD COLUMN " .. column[2] .. ";") then
                return false
            end
        end
    end
    return Base.exec([[
CREATE INDEX IF NOT EXISTS idx_books_md5 ON books(source_id, md5);
CREATE INDEX IF NOT EXISTS idx_books_path ON books(path);
CREATE INDEX IF NOT EXISTS idx_books_library ON books(source_id, deleted, stable_id);
CREATE INDEX IF NOT EXISTS idx_books_sync ON books(source_id, sync_status);
]]) ~= nil
end

--- 插入或更新 books 行（本地可信写入：扫盘/本地登记），标脏待上传。
---@param row table
---@return boolean
function BookDB.upsert(row)
    local source_id = row.source_id
    local stable_id = row.stable_id
    local now = tonumber(row.inserted_at) or os.time()
    return Base.exec(
        [[INSERT INTO books (
            source_id, stable_id, md5, title, authors,
            category, series, intro, cover, inserted_at, path, deleted, sync_status
          ) VALUES (?,?,?,?,?,?,?,?,?,?,?,0,0)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            md5=COALESCE(excluded.md5, books.md5),
            title=COALESCE(NULLIF(excluded.title, ''), books.title),
            authors=COALESCE(NULLIF(excluded.authors, ''), books.authors),
            category=excluded.category,
            series=excluded.series,
            intro=COALESCE(NULLIF(excluded.intro, ''), books.intro),
            cover=COALESCE(NULLIF(excluded.cover, ''), books.cover),
            path=COALESCE(excluded.path, books.path),
            deleted=0,
            sync_status=0;]],
        source_id,
        stable_id,
        row.md5,
        row.title,
        row.authors,
        row.category,
        row.series,
        row.intro,
        row.cover,
        now,
        row.path
    ) ~= nil
end

--- 远端书架行写入。本地脏行（sync_status=0）保留展示字段。
---@param row table
---@return boolean
function BookDB.upsertRemote(row)
    local source_id = row.source_id
    local stable_id = row.stable_id
    local has_membership = row.deleted ~= nil
    local deleted = 1
    if row.deleted ~= nil then
        deleted = (row.deleted == true or tonumber(row.deleted) == 1) and 1 or 0
    end
    local now = tonumber(row.inserted_at) or os.time()
    return Base.exec(
        [[INSERT INTO books (
            source_id, stable_id, md5, title, authors, category,
            series, intro, cover, inserted_at, path, deleted, sync_status
          ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,1)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            md5=COALESCE(excluded.md5, books.md5),
            title=CASE WHEN books.sync_status=0
                THEN books.title ELSE COALESCE(excluded.title, books.title) END,
            authors=CASE WHEN books.sync_status=0
                THEN books.authors ELSE COALESCE(excluded.authors, books.authors) END,
            category=CASE WHEN books.sync_status=0
                THEN books.category ELSE COALESCE(excluded.category, books.category) END,
            series=CASE WHEN books.sync_status=0
                THEN books.series ELSE COALESCE(excluded.series, books.series) END,
            intro=CASE WHEN books.sync_status=0
                THEN books.intro ELSE COALESCE(excluded.intro, books.intro) END,
            cover=COALESCE(NULLIF(excluded.cover, ''), books.cover),
            path=COALESCE(excluded.path, books.path),
            deleted=CASE
                WHEN books.sync_status=0 THEN books.deleted
                WHEN ?=1 THEN excluded.deleted
                ELSE books.deleted END,
            sync_status=CASE
                WHEN books.sync_status=0 THEN 0
                WHEN ?=1 THEN 1
                ELSE books.sync_status END;]],
        source_id, stable_id, row.md5, row.title, row.authors,
        row.category, row.series, row.intro, row.cover, now, row.path,
        deleted,
        has_membership and 1 or 0, has_membership and 1 or 0
    ) ~= nil
end

--- 批量写入远端行；按“是否明确携带书架成员关系”分组。
---@param rows table[]
---@return boolean
function BookDB.upsertRemoteMany(rows)
    for _, row in ipairs(rows) do
        if not BookDB.upsertRemote(row) then return false end
    end
    return true
end

--- 用户编辑/刮削写入展示元数据，标脏待上传。
---@param row table
---@return boolean
function BookDB.upsertLocal(row)
    local source_id = row.source_id
    local stable_id = row.stable_id
    local now = tonumber(row.inserted_at) or os.time()
    return Base.exec(
        [[INSERT INTO books (
            source_id, stable_id, title, authors, category,
            series, intro, inserted_at, deleted, sync_status
          ) VALUES (?,?,?,?,?,?,?,?,0,0)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            title=excluded.title, authors=excluded.authors,
            category=excluded.category,
            series=excluded.series, intro=excluded.intro,
            deleted=0,
            sync_status=CASE WHEN books.deleted=1 THEN 0 ELSE books.sync_status END;]],
        source_id, stable_id, row.title, row.authors,
        row.category, row.series, row.intro, now
    ) ~= nil
end

--- 远端书架快照入库：先把当前在架标软删，再 upsert 远端成员。
---@param source_id string
---@param books table[]
---@param opts { clear_missing_paths: boolean|nil }|nil
---@return boolean
function BookDB.reconcile(source_id, books, opts)
    opts = opts or {}
    if not Base.exec("BEGIN IMMEDIATE;") then return false end
    local deactivate = opts.clear_missing_paths
        and [[UPDATE books SET deleted=1, path=NULL
            WHERE source_id=? AND deleted=0 AND sync_status=1;]]
        or [[UPDATE books SET deleted=1
            WHERE source_id=? AND deleted=0 AND sync_status=1;]]
    local ok = Base.exec(deactivate, source_id) ~= nil
    local batch = {}
    for _, row in ipairs(books) do
        local copy = {}
        for k, v in pairs(row) do copy[k] = v end
        copy.source_id = source_id
        copy.deleted = 0
        batch[#batch + 1] = copy
    end
    if ok then ok = BookDB.upsertRemoteMany(batch) end
    if ok and Base.exec("COMMIT;") then return true end
    Base.exec("ROLLBACK;")
    return false
end

--- 设置书架成员：on_shelf=true → deleted=0；false → deleted=1（软删待同步）。
---@param source_id string
---@param stable_id string
---@param on_shelf boolean
---@param clear_path boolean|nil
---@return boolean
function BookDB.setLibraryMembership(source_id, stable_id, on_shelf, clear_path)
    local deleted = on_shelf and 0 or 1
    if clear_path and not on_shelf then
        return Base.exec([[UPDATE books SET deleted=1, path=NULL, sync_status=0
            WHERE source_id=? AND stable_id=?;]], source_id, stable_id) ~= nil
    end
    return Base.exec([[UPDATE books SET deleted=?, sync_status=0
        WHERE source_id=? AND stable_id=?;]],
        deleted, source_id, stable_id) ~= nil
end

--- 本地删除：标 deleted=1、sync_status=0。书架立刻消失，等同步时推云端真删。
---@param source_id string
---@param stable_id string
---@return boolean
function BookDB.markDeleted(source_id, stable_id)
    return BookDB.setLibraryMembership(source_id, stable_id, false, true)
end

--- 单列字符串查询 → string[]
---@param sql string
---@param ... any
---@return string[]
local function stringColumn(sql, ...)
    local result, nrows = Base.query(sql, ...)
    local out = {}
    for i = 1, nrows do
        out[i] = result[1][i]
    end
    return out
end

--- 待推送到云端删除的 stable_id（deleted=1 且脏）。
---@param source_id string
---@return string[]
function BookDB.pendingDeleteIds(source_id)
    return stringColumn([[SELECT stable_id FROM books
          WHERE source_id=? AND deleted=1 AND sync_status=0
          ORDER BY inserted_at ASC;]], source_id)
end

--- 待推送到云端加架的 stable_id（deleted=0 且脏）。
---@param source_id string
---@return string[]
function BookDB.pendingShelfAddIds(source_id)
    return stringColumn([[SELECT stable_id FROM books
          WHERE source_id=? AND deleted=0 AND sync_status=0
          ORDER BY inserted_at ASC;]], source_id)
end

local COLUMNS =
    "source_id, stable_id, md5, title, authors, category, series, intro, cover, inserted_at, path, deleted, sync_status, read_state"

--- rowexec 位置参数 → Book 表
---@return Book|nil
local function rowToBook(source_id_r, stable_id_r, digest, title, authors, category, series, intro, cover, inserted_at, path, deleted, sync_status, read_state)
    if not source_id_r then
        return nil
    end
    local del = tonumber(deleted) or 1
    return {
        source_id = source_id_r,
        stable_id = stable_id_r,
        md5 = digest,
        title = title,
        authors = authors,
        category = category,
        series = series,
        intro = intro,
        cover = cover,
        inserted_at = tonumber(inserted_at) or 0,
        path = path,
        deleted = del,
        sync_status = tonumber(sync_status) or 1,
        read_state = tonumber(read_state) or 0,
        percent = 0,
    }
end

--- Base.query 列式结果的第 i 行 → Book
---@return Book|nil
local function bookAt(result, i)
    local row = {}
    for c = 1, #result do row[c] = result[c][i] end
    return rowToBook(unpack(row, 1, #result))
end

--- 按 (source_id, stable_id) 取 books 行
---@param source_id string
---@param stable_id string
---@return Book|nil
function BookDB.get(source_id, stable_id)
    return rowToBook(Base.rowexec(
        "SELECT " .. COLUMNS .. " FROM books WHERE source_id=? AND stable_id=? LIMIT 1;",
        source_id,
        stable_id
    ))
end

--- 批量取 books 行，避免统计/列表场景的 N+1 查询。
---@param source_id string
---@param stable_ids string[]
---@return table<string, Book>
function BookDB.getMany(source_id, stable_ids)
    local ids, seen = {}, {}
    for _, stable_id in ipairs(stable_ids) do
        if not seen[stable_id] then
            seen[stable_id] = true
            ids[#ids + 1] = stable_id
        end
    end
    if #ids == 0 then return {} end

    local out = {}
    for start = 1, #ids, 500 do
        local finish = math.min(start + 499, #ids)
        local result, nrows = Base.query(
            "SELECT " .. COLUMNS .. " FROM books WHERE source_id=? AND stable_id IN ("
                .. string.rep("?", finish - start + 1, ",") .. ");",
            source_id, unpack(ids, start, finish)
        )
        for i = 1, nrows do
            local book = bookAt(result, i)
            out[book.stable_id] = book
        end
    end
    return out
end

--- 按本地路径取 books 行
---@param path string
---@return Book|nil
function BookDB.getByPath(path)
    return rowToBook(Base.rowexec(
        "SELECT " .. COLUMNS .. " FROM books WHERE path=? LIMIT 1;",
        path
    ))
end

--- 文件落地后登记物理路径。
--- 行不存在时补身份行：deleted=1（非书架成员）、sync_status=1。
---@param source_id string
---@param stable_id string
---@param path string
---@return boolean
function BookDB.touchPath(source_id, stable_id, path)
    return Base.exec(
        [[INSERT INTO books (source_id, stable_id, inserted_at, path, deleted, sync_status)
          VALUES (?,?,0,?,1,1)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            path=excluded.path;]],
        source_id,
        stable_id,
        path
    ) ~= nil
end

--- 手动标记已读/未读。
--- 已读：read_state=1 且进度抬到 100%（脏写 pending_progress）。
--- 未读：read_state=2；不回退进度。
---@param source_id string
---@param stable_id string
---@param is_read boolean
---@return boolean
function BookDB.setRead(source_id, stable_id, is_read)
    if not is_read then
        return Base.exec([[UPDATE books SET read_state=2
            WHERE source_id=? AND stable_id=?;]],
            source_id, stable_id) ~= nil
    end
    if not Base.exec([[UPDATE books SET read_state=1
        WHERE source_id=? AND stable_id=?;]],
        source_id, stable_id) then
        return false
    end
    return Base.exec([[
INSERT INTO pending_progress
  (source_id, stable_id, fraction, updated_at, sync_status)
VALUES (?,?,1,?,0)
ON CONFLICT(source_id, stable_id) DO UPDATE SET
  fraction=1,
  sync_status=0,
  updated_at=excluded.updated_at;]],
        source_id, stable_id, os.time()) ~= nil
end

--- 自动标记已读；只允许更新从未被用户强制标为未读的书。
---@param source_id string
---@param stable_id string
---@return boolean
function BookDB.markReadAutomatically(source_id, stable_id)
    return Base.exec([[UPDATE books SET read_state=1
        WHERE source_id=? AND stable_id=? AND read_state=0;]],
        source_id, stable_id) ~= nil
end

--- 完整读到 100% 后标记已读；完成事实优先于手动未读。
---@param source_id string
---@param stable_id string
---@return boolean
function BookDB.markReadComplete(source_id, stable_id)
    return Base.exec([[UPDATE books SET read_state=1
        WHERE source_id=? AND stable_id=?;]],
        source_id, stable_id) ~= nil
end

--- 清掉某目录下全部 path 登记
---@param dir string
---@return boolean
function BookDB.clearPathsUnder(dir)
    if not dir or dir == "" then
        return false
    end
    return Base.exec(
        [[UPDATE books SET path=NULL WHERE path LIKE ? ESCAPE '\';]],
        dir:gsub("([%%_\\])", "\\%1") .. "/%"
    ) ~= nil
end

--- 按 (source_id, md5) 找已入库的行
---@param source_id string
---@param md5 string
---@return Book|nil
function BookDB.getByMd5(source_id, md5)
    return rowToBook(Base.rowexec(
        "SELECT " .. COLUMNS .. " FROM books WHERE source_id=? AND md5=? LIMIT 1;",
        source_id,
        md5
    ))
end

--- 改名/移动：把某本书的 stable_id 换成新值
---@param source_id string
---@param old_stable_id string
---@param new_stable_id string
---@param category string|nil
---@param series string|nil
---@return boolean
function BookDB.renameStableId(source_id, old_stable_id, new_stable_id, category, series)
    if old_stable_id == new_stable_id then
        return true
    end
    if not Base.exec([[BEGIN IMMEDIATE;]]) then
        return false
    end
    local ok = Base.exec(
        [[UPDATE books SET stable_id=?, category=?, series=?, path=? WHERE source_id=? AND stable_id=?;]],
        new_stable_id, category, series, new_stable_id, source_id, old_stable_id
    ) and Base.exec(
        [[UPDATE chapters SET stable_id=? WHERE source_id=? AND stable_id=?;]],
        new_stable_id, source_id, old_stable_id
    ) and Base.exec(
        [[UPDATE reading_stats SET stable_id=? WHERE source_id=? AND stable_id=?;]],
        new_stable_id, source_id, old_stable_id
    ) and Base.exec(
        [[UPDATE notes SET stable_id=? WHERE source_id=? AND stable_id=?;]],
        new_stable_id, source_id, old_stable_id
    ) and Base.exec(
        [[UPDATE pending_progress SET stable_id=? WHERE source_id=? AND stable_id=?;]],
        new_stable_id, source_id, old_stable_id
    ) and Base.exec(
        [[UPDATE xray_entities SET stable_id=? WHERE source_id=? AND stable_id=?;]],
        new_stable_id, source_id, old_stable_id
    )
    if ok and Base.exec([[COMMIT;]]) then
        return true
    end
    Base.exec([[ROLLBACK;]])
    return false
end

--- 取某源全部 stable_id
---@param source_id string
---@return string[]
function BookDB.stableIdsBySource(source_id)
    return stringColumn([[SELECT stable_id FROM books WHERE source_id=?;]], source_id)
end

--- 取某源当前书架内全部 stable_id。
---@param source_id string
---@return string[]
function BookDB.libraryStableIdsBySource(source_id)
    return stringColumn([[SELECT stable_id FROM books
        WHERE source_id=? AND deleted=0 ORDER BY stable_id;]], source_id)
end

--- 某源待上传书架行。
---@param source_id string
---@return Book[]
function BookDB.unsynced(source_id)
    local result, nrows = Base.query(
        "SELECT " .. COLUMNS .. " FROM books WHERE source_id=? AND sync_status=0 ORDER BY inserted_at ASC;",
        source_id
    )
    local out = {}
    for i = 1, nrows do
        out[i] = bookAt(result, i)
    end
    return out
end

--- push 成功后清脏。
---@param source_id string
---@param stable_id string
---@return boolean
function BookDB.markSynced(source_id, stable_id)
    return Base.exec([[UPDATE books SET sync_status=1
        WHERE source_id=? AND stable_id=?;]], source_id, stable_id) ~= nil
end

--- 按源分页查询书库。
---@param source_id string|string[]
---@param opts table|nil
---@return table[] rows, number count
function BookDB.listBySource(source_id, opts)
    opts = opts or {}
    local where, args = Base.sourceClause("b.source_id", source_id)
    where = where .. " AND b.deleted=0"
    if type(opts.source_id) == "string" and opts.source_id ~= "" then
        where = where .. " AND b.source_id=?"
        args[#args + 1] = opts.source_id
    end
    if opts.uncategorized then
        where = where .. " AND (b.category IS NULL OR b.category='')"
    elseif opts.category and opts.category ~= "" then
        where = where .. " AND b.category=?"
        args[#args + 1] = opts.category
    end
    if opts.unseries then
        where = where .. " AND (b.series IS NULL OR b.series='')"
    elseif opts.series and opts.series ~= "" then
        where = where .. " AND b.series=?"
        args[#args + 1] = opts.series
    end
    if opts.search and opts.search ~= "" then
        where = where .. [[ AND (b.title LIKE ? ESCAPE '\' OR b.authors LIKE ? ESCAPE '\' OR b.stable_id LIKE ? ESCAPE '\')]]
        local like = "%" .. opts.search:gsub("([%%_\\])", "\\%1") .. "%"
        args[#args + 1] = like
        args[#args + 1] = like
        args[#args + 1] = like
    end
    if opts.read_status == "read" then
        where = where .. " AND b.read_state=1"
    elseif opts.read_status == "unread" then
        where = where .. " AND b.read_state<>1"
    end
    local total = Base.rowexec(
        "SELECT COUNT(*) FROM books b WHERE " .. where .. ";",
        unpack(args)
    )
    total = tonumber(total) or 0
    if total == 0 then
        return {}, 0
    end
    local limit = tonumber(opts.limit) or 0
    local offset = tonumber(opts.offset) or 0
    local sort_sql = {
        title = "COALESCE(b.title, '') COLLATE NOCASE %s, b.stable_id ASC",
        author = "COALESCE(b.authors, '') COLLATE NOCASE %s, COALESCE(b.title, '') COLLATE NOCASE %s, b.stable_id ASC",
        recent_read = "COALESCE(p.updated_at, 0) DESC, b.stable_id ASC",
        recent_added = "b.inserted_at DESC, b.stable_id ASC",
    }
    local order = (sort_sql[opts.sort] or sort_sql.recent_added)
        :gsub("%%s", opts.sort_desc and "DESC" or "ASC")
    local sel = [[SELECT b.source_id, b.stable_id, b.title, b.authors,
                        COALESCE(p.fraction * 100, 0),
                        b.category, b.series, b.intro, b.cover, b.inserted_at,
                        b.read_state, b.path
                   FROM books b LEFT JOIN pending_progress p
                     ON p.source_id=b.source_id AND p.stable_id=b.stable_id
                   WHERE ]] .. where .. " ORDER BY " .. order
    if limit > 0 then
        sel = sel .. " LIMIT ? OFFSET ?"
        args[#args + 1] = limit
        args[#args + 1] = math.max(0, offset)
    end
    local result, nrows = Base.query(sel .. ";", unpack(args))
    local rows = {}
    for i = 1, nrows do
        rows[i] = {
            source_id = result[1][i],
            stable_id = result[2][i],
            title = result[3][i],
            authors = result[4][i],
            percent = tonumber(result[5][i]) or 0,
            category = result[6][i],
            series = result[7][i],
            intro = result[8][i],
            cover = result[9][i],
            inserted_at = tonumber(result[10][i]) or 0,
            read_state = tonumber(result[11][i]) or 0,
            path = result[12][i],
            deleted = 0,
        }
    end
    return rows, total
end

--- 书架内某文本列（category / series）的非空去重值
---@param column string 可信列名
---@param source_id string|string[]
---@return string[]
local function distinctValues(column, source_id)
    local where, args = Base.sourceClause("source_id", source_id)
    return stringColumn(
        "SELECT DISTINCT " .. column .. " FROM books WHERE " .. where .. " AND deleted=0 AND "
            .. column .. " IS NOT NULL AND " .. column .. "<>'' ORDER BY " .. column .. ";",
        unpack(args)
    )
end

--- 书架按某文本列（category / series）聚合册数；空值归到 ''，排在最后
---@param column string 可信列名，同时是返回行的键
---@param source_id string|string[]
---@return table[]
local function countsBy(column, source_id)
    local where, args = Base.sourceClause("source_id", source_id)
    local bucket = "CASE WHEN " .. column .. " IS NULL OR " .. column .. "='' THEN '' ELSE " .. column .. " END"
    local result, nrows = Base.query(
        "SELECT " .. bucket .. ", COUNT(*) FROM books WHERE " .. where .. " AND deleted=0"
            .. " GROUP BY " .. bucket
            .. " ORDER BY CASE WHEN " .. column .. " IS NULL OR " .. column .. "='' THEN 1 ELSE 0 END, "
            .. column .. ";",
        unpack(args)
    )
    local rows = {}
    for i = 1, nrows do
        rows[i] = { [column] = result[1][i] or "", count = tonumber(result[2][i]) or 0 }
    end
    return rows
end

--- 某源的书库分类列表
---@param source_id string|string[]
---@return string[]
function BookDB.categoriesBySource(source_id)
    return distinctValues("category", source_id)
end

--- 某源书架按分类聚合
---@param source_id string|string[]
---@return { category: string, count: integer }[]
function BookDB.categoryCountsBySource(source_id)
    return countsBy("category", source_id)
end

--- 某源的书库系列列表
---@param source_id string|string[]
---@return string[]
function BookDB.seriesBySource(source_id)
    return distinctValues("series", source_id)
end

--- 某源书架按系列聚合
---@param source_id string|string[]
---@return { series: string, count: integer }[]
function BookDB.seriesCountsBySource(source_id)
    return countsBy("series", source_id)
end

--- 范围内按 source_id 聚合册数
---@param source_id string|string[]
---@return { source_id: string, count: integer }[]
function BookDB.sourceCountsBySource(source_id)
    local where, args = Base.sourceClause("source_id", source_id)
    local result, nrows = Base.query(
        [[SELECT source_id, COUNT(*)
          FROM books
          WHERE ]] .. where .. [[ AND deleted=0
          GROUP BY source_id
          ORDER BY source_id;]],
        unpack(args)
    )
    local rows = {}
    for i = 1, nrows do
        rows[i] = { source_id = result[1][i], count = tonumber(result[2][i]) or 0 }
    end
    return rows
end

--- 某源书架按阅读状态聚合（read / unread）。
---@param source_id string|string[]
---@return { status: "read"|"unread", count: integer }[]
function BookDB.readStatusCountsBySource(source_id)
    local where, args = Base.sourceClause("source_id", source_id)
    local result, nrows = Base.query(
        [[SELECT CASE
                   WHEN read_state=1 THEN 'read'
                   ELSE 'unread'
                 END,
                 COUNT(*)
          FROM books
          WHERE ]] .. where .. [[ AND deleted=0
          GROUP BY CASE
                     WHEN read_state=1 THEN 'read'
                     ELSE 'unread'
                   END;]],
        unpack(args)
    )
    local counts = { read = 0, unread = 0 }
    for i = 1, nrows do
        counts[result[1][i]] = tonumber(result[2][i]) or 0
    end
    return {
        { status = "read", count = counts.read },
        { status = "unread", count = counts.unread },
    }
end

--- 按 (source_id, stable_id) 删除 books 行
---@param source_id string
---@param stable_id string
---@return boolean
function BookDB.remove(source_id, stable_id)
    return Base.exec(
        [[DELETE FROM books WHERE source_id=? AND stable_id=?;]],
        source_id, stable_id
    ) ~= nil
end

--- 读取书籍目录缓存；max_age 秒内才命中。
---@param source_id string
---@param stable_id string
---@param max_age number|nil
---@return string|nil, number|nil
function BookDB.getToc(source_id, stable_id, max_age)
    local payload, toc_at = Base.rowexec(
        [[SELECT toc, toc_fetched_at FROM books
          WHERE source_id=? AND stable_id=? LIMIT 1;]],
        source_id, stable_id
    )
    if not payload then return nil end
    toc_at = tonumber(toc_at) or 0
    if max_age and os.time() - toc_at >= max_age then
        return nil
    end
    return payload, toc_at
end

--- 写入书籍目录缓存。
---@param source_id string
---@param stable_id string
---@param payload string
---@return boolean
function BookDB.setToc(source_id, stable_id, payload)
    return Base.exec(
        [[INSERT INTO books (source_id, stable_id, toc, toc_fetched_at, deleted, sync_status)
          VALUES (?,?,?,?,1,1)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            toc=excluded.toc,
            toc_fetched_at=excluded.toc_fetched_at;]],
        source_id, stable_id, payload, os.time()
    ) ~= nil
end

--- 读取全书阅读排版偏好（JSON 串）。
---@param source_id string
---@param stable_id string
---@return string|nil
function BookDB.getReaderPrefs(source_id, stable_id)
    return (Base.rowexec(
        [[SELECT reader_prefs FROM books WHERE source_id=? AND stable_id=? LIMIT 1;]],
        source_id,
        stable_id
    ))
end

--- 写入全书阅读排版偏好（JSON 串）。
--- 新建行 deleted=1：存排版 ≠ 上架。
---@param source_id string
---@param stable_id string
---@param payload string
---@return boolean
function BookDB.setReaderPrefs(source_id, stable_id, payload)
    return Base.exec(
        [[INSERT INTO books (source_id, stable_id, reader_prefs, deleted, sync_status)
          VALUES (?, ?, ?, 1, 1)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            reader_prefs=excluded.reader_prefs;]],
        source_id,
        stable_id,
        payload
    ) ~= nil
end

return BookDB
