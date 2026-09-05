--[[--
books 表：BookIdentity + 展示元数据 + 统计 md5

@module koplugin.book.db.book
--]]

local Base = require("db.base")

local BookDB = {}

--- 创建 books 表及其常用索引。
--- 仅在 Base.open() 的一次性 schema 初始化阶段调用。
---@return boolean 成功返回 true，SQL 失败返回 false
function BookDB.ensureSchema()
    if not Base.exec([[
CREATE TABLE IF NOT EXISTS books (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL, md5 TEXT, title TEXT,
  authors TEXT, percent REAL DEFAULT 0, category TEXT,
  series TEXT, intro TEXT, cover TEXT, fetched_at INTEGER NOT NULL DEFAULT 0, path TEXT,
  in_library INTEGER NOT NULL DEFAULT 1, metadata_dirty INTEGER NOT NULL DEFAULT 0,
  metadata_updated_at INTEGER NOT NULL DEFAULT 0, reader_prefs TEXT,
  toc TEXT, toc_fetched_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source_id, stable_id)
);
CREATE INDEX IF NOT EXISTS idx_books_md5 ON books(source_id, md5);
CREATE INDEX IF NOT EXISTS idx_books_path ON books(path);
CREATE INDEX IF NOT EXISTS idx_books_library ON books(source_id, in_library, stable_id);
]]) then return false end
    local columns, nrows = Base.query("PRAGMA table_info(books);")
    local has_cover = false
    for i = 1, nrows do
        if columns[2][i] == "cover" then
            has_cover = true
            break
        end
    end
    if not has_cover and not Base.exec("ALTER TABLE books ADD COLUMN cover TEXT;") then
        return false
    end
    return true
end

--- 插入或更新 books 行（本地可信写入：扫盘/本地登记），不制造待上传状态。
---@param row table
---@return boolean
function BookDB.upsert(row)
    local source_id = row.source_id
    local stable_id = row.stable_id
    return Base.exec(
        [[INSERT INTO books (
            source_id, stable_id, md5, title, authors,
            percent, category, series, intro, cover, fetched_at, path, in_library
          ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,1)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            md5=COALESCE(excluded.md5, books.md5),
            title=excluded.title,
            authors=excluded.authors,
            percent=excluded.percent,
            category=excluded.category,
            series=excluded.series,
            intro=excluded.intro,
            cover=COALESCE(excluded.cover, books.cover),
            fetched_at=excluded.fetched_at,
            path=COALESCE(excluded.path, books.path),
            in_library=1;]],
        source_id,
        stable_id,
        row.md5,
        row.title,
        row.authors,
        tonumber(row.percent) or 0,
        row.category,
        row.series,
        row.intro,
        row.cover,
        tonumber(row.fetched_at) or os.time(),
        row.path
    ) ~= nil
end

--- 远端书架行写入。存在本地编辑时保留本地展示元数据。
---@param row table
---@return boolean
function BookDB.upsertRemote(row)
    local source_id = row.source_id
    local stable_id = row.stable_id
    local has_membership = row.in_library ~= nil
    local in_library = row.in_library == true or tonumber(row.in_library) == 1
    return Base.exec(
        [[INSERT INTO books (
            source_id, stable_id, md5, title, authors, percent, category,
            series, intro, cover, fetched_at, path, in_library,
            metadata_dirty, metadata_updated_at
          ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,0,0)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            md5=COALESCE(excluded.md5, books.md5),
            title=CASE WHEN books.metadata_dirty=0
                THEN COALESCE(excluded.title, books.title) ELSE books.title END,
            authors=CASE WHEN books.metadata_dirty=0
                THEN COALESCE(excluded.authors, books.authors) ELSE books.authors END,
            category=CASE WHEN books.metadata_dirty=0
                THEN COALESCE(excluded.category, books.category) ELSE books.category END,
            series=CASE WHEN books.metadata_dirty=0
                THEN COALESCE(excluded.series, books.series) ELSE books.series END,
            intro=CASE WHEN books.metadata_dirty=0
                THEN COALESCE(excluded.intro, books.intro) ELSE books.intro END,
            cover=COALESCE(excluded.cover, books.cover),
            percent=excluded.percent,
            fetched_at=excluded.fetched_at,
            path=COALESCE(excluded.path, books.path),
            in_library=CASE WHEN ?=1 THEN excluded.in_library ELSE books.in_library END;]],
        source_id, stable_id, row.md5, row.title, row.authors,
        tonumber(row.percent) or 0, row.category,
        row.series, row.intro, row.cover, tonumber(row.fetched_at) or os.time(), row.path,
        in_library and 1 or 0, has_membership and 1 or 0
    ) ~= nil
end

--- 批量写入远端书架行。大书架同步不能为每本书 prepare/close 一次；
--- 每批 8 行（88 个绑定参数）：兼容低端设备上的 SQLite/LuaJIT 绑定实现，
--- 同时避免每本书都重复 prepare/close。
---@param rows table[]
---@return boolean
function BookDB.upsertRemoteMany(rows)
    if #rows == 0 then return true end
    for start = 1, #rows, 8 do
        local values, args = {}, {}
        local finish = math.min(start + 7, #rows)
        -- 绑定参数允许 NULL，不能用 #args+1 追加（nil 不增长表长，后续列会整体左移错位）；
        -- 按 (行序-1)*11 + 列序 显式定位。
        for i = start, finish do
            local row = rows[i]
            local base = #values * 12
            values[#values + 1] = "(?,?,?,?,?,?,?,?,?,?,?,?,1)"
            args[base + 1] = row.source_id
            args[base + 2] = row.stable_id
            args[base + 3] = row.md5
            args[base + 4] = row.title
            args[base + 5] = row.authors
            args[base + 6] = tonumber(row.percent) or 0
            args[base + 7] = row.category
            args[base + 8] = row.series
            args[base + 9] = row.intro
            args[base + 10] = row.cover
            args[base + 11] = tonumber(row.fetched_at) or os.time()
            args[base + 12] = row.path
        end
        local ok = Base.exec(
            [[INSERT INTO books (
                source_id, stable_id, md5, title, authors, percent, category,
                series, intro, cover, fetched_at, path, in_library
              ) VALUES ]] .. table.concat(values, ",") .. [[
              ON CONFLICT(source_id, stable_id) DO UPDATE SET
                md5=COALESCE(excluded.md5, books.md5),
                title=CASE WHEN books.metadata_dirty=0
                    THEN COALESCE(excluded.title, books.title) ELSE books.title END,
                authors=CASE WHEN books.metadata_dirty=0
                    THEN COALESCE(excluded.authors, books.authors) ELSE books.authors END,
                category=CASE WHEN books.metadata_dirty=0
                    THEN COALESCE(excluded.category, books.category) ELSE books.category END,
                series=CASE WHEN books.metadata_dirty=0
                    THEN COALESCE(excluded.series, books.series) ELSE books.series END,
                intro=CASE WHEN books.metadata_dirty=0
                    THEN COALESCE(excluded.intro, books.intro) ELSE books.intro END,
                cover=COALESCE(excluded.cover, books.cover),
                percent=excluded.percent,
                fetched_at=excluded.fetched_at,
                path=COALESCE(excluded.path, books.path),
                in_library=1;]],
            -- args 内允许 NULL；不能用不带上界的 unpack，否则会在第一个 nil 处截断。
            unpack(args, 1, #values * 12)
        )
        if not ok then
            -- 某些旧版 SQLite/绑定对多行 UPSERT 支持不完整；批量失败时回退
            -- 单行写入，不能让一次刷新把整个书架清空。
            for i = start, finish do
                if not BookDB.upsertRemote(rows[i]) then return false end
            end
        end
    end
    return true
end

--- 用户编辑展示元数据；版本用于异步确认，旧回调不能清掉新编辑。
---@param row table
---@return boolean
function BookDB.upsertLocal(row)
    local source_id = row.source_id
    local stable_id = row.stable_id
    local revision = tonumber(row.metadata_updated_at) or os.time()
    return Base.exec(
        [[INSERT INTO books (
            source_id, stable_id, title, authors, percent, category,
            series, intro, fetched_at, in_library, metadata_dirty, metadata_updated_at
          ) VALUES (?,?,?,?,?,?,?,?,?,1,1,?)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            title=excluded.title, authors=excluded.authors,
            category=excluded.category,
            series=excluded.series, intro=excluded.intro,
            fetched_at=excluded.fetched_at, in_library=1,
            metadata_dirty=1, metadata_updated_at=excluded.metadata_updated_at;]],
        source_id, stable_id, row.title, row.authors, tonumber(row.percent) or 0,
        row.category, row.series, row.intro,
        tonumber(row.fetched_at) or os.time(), revision
    ) ~= nil
end

--- 远端书架快照入库：先 upsert 全部条目，再把本次未刷新的成员标为不活跃（不删行）。
---@param source_id string
---@param books table[]
---@return boolean
function BookDB.reconcile(source_id, books)
    if not Base.exec("BEGIN IMMEDIATE;") then return false end
    local sync_at = os.time()
    local batch = {}
    for _, row in ipairs(books) do
        local copy = {}
        for k, v in pairs(row) do copy[k] = v end
        copy.source_id = source_id
        copy.in_library = true
        copy.fetched_at = sync_at
        batch[#batch + 1] = copy
    end
    local ok = BookDB.upsertRemoteMany(batch)
    if ok then
        ok = Base.exec(
            [[UPDATE books SET in_library=0
              WHERE source_id=? AND fetched_at<? AND in_library=1;]],
            source_id, sync_at
        ) ~= nil
    end
    if ok and Base.exec("COMMIT;") then return true end
    Base.exec("ROLLBACK;")
    return false
end

---@param source_id string
---@param stable_id string
---@param in_library boolean
---@param clear_path boolean|nil
---@return boolean
function BookDB.setLibraryMembership(source_id, stable_id, in_library, clear_path)
    if clear_path and not in_library then
        return Base.exec([[UPDATE books SET in_library=0, path=NULL
            WHERE source_id=? AND stable_id=?;]], source_id, stable_id) ~= nil
    end
    return Base.exec([[UPDATE books SET in_library=? WHERE source_id=? AND stable_id=?;]],
        in_library and 1 or 0, source_id, stable_id) ~= nil
end

local COLUMNS =
    "source_id, stable_id, md5, title, authors, percent, category, series, intro, cover, fetched_at, path, in_library, metadata_dirty, metadata_updated_at"

--- rowexec 位置参数 → Book 表
--- 形参顺序必须与 COLUMNS 一致；sqlite 返回的都是字符串，数值列在此统一 tonumber。
---@param source_id_r string|nil 为 nil 表示没查到行
---@param stable_id_r string|nil
---@param digest string|nil books.md5 列
---@param title string|nil
---@param authors string|nil
---@param percent any 阅读进度 0..100
---@param category string|nil
---@param series string|nil
---@param intro string|nil
---@param cover string|nil
---@param fetched_at any 元数据拉取时间戳，缺失算 0
---@param path string|nil 本地文件路径
---@param in_library any 非 0 即视为在书架内
---@param metadata_dirty any
---@param metadata_updated_at any
---@return Book|nil
local function rowToBook(source_id_r, stable_id_r, digest, title, authors, percent, category, series, intro, cover, fetched_at, path, in_library, metadata_dirty, metadata_updated_at)
    if not source_id_r then
        return nil
    end
    return {
        source_id = source_id_r,
        stable_id = stable_id_r,
        md5 = digest,
        title = title,
        authors = authors,
        percent = tonumber(percent) or 0,
        category = category,
        series = series,
        intro = intro,
        cover = cover,
        fetched_at = tonumber(fetched_at) or 0,
        path = path,
        in_library = tonumber(in_library) ~= 0,
        metadata_dirty = tonumber(metadata_dirty) or 0,
        metadata_updated_at = tonumber(metadata_updated_at) or 0,
    }
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
    -- Keep below SQLite's usual 999 bind parameter limit.
    for start = 1, #ids, 500 do
        local finish = math.min(start + 499, #ids)
        local placeholders = {}
        for _ = start, finish do placeholders[#placeholders + 1] = "?" end
        local args = { source_id }
        for i = start, finish do args[#args + 1] = ids[i] end
        local result, nrows = Base.query(
            "SELECT " .. COLUMNS .. " FROM books WHERE source_id=? AND stable_id IN ("
                .. table.concat(placeholders, ",") .. ");",
            unpack(args)
        )
        if result and nrows and nrows > 0 then
            for i = 1, nrows do
                local row = {}
                for c = 1, #result do row[c] = result[c][i] end
                local book = rowToBook(unpack(row, 1, #result))
                if book then out[book.stable_id] = book end
            end
        end
    end
    return out
end

--- 按本地路径取 books 行（身份解析唯一入口：整本书精确匹配）
---@param path string
---@return Book|nil
function BookDB.getByPath(path)
    return rowToBook(Base.rowexec(
        "SELECT " .. COLUMNS .. " FROM books WHERE path=? LIMIT 1;",
        path
    ))
end

--- 文件落地后登记物理路径。
--- 行不存在时补一行身份（fetched_at=0 表示仅身份行）。
---@param source_id string
---@param stable_id string
---@param path string
---@return boolean
function BookDB.touchPath(source_id, stable_id, path)
    return Base.exec(
        [[INSERT INTO books (source_id, stable_id, fetched_at, path)
          VALUES (?,?,0,?)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            path=excluded.path;]],
        source_id,
        stable_id,
        path
    ) ~= nil
end

--- 清掉指向某文件的 path 登记（缓存失效；不动身份行本身）
---@param path string
---@return boolean
function BookDB.clearPath(path)
    return Base.exec(
        [[UPDATE books SET path=NULL WHERE path=?;]],
        path
    ) ~= nil
end

--- 清掉某目录下全部 path 登记（缓存目录被清理）
---@param dir string
---@return boolean
function BookDB.clearPathsUnder(dir)
    -- 空目录会拼成 LIKE '/%'，会清掉全部绝对路径登记。
    if not dir or dir == "" then
        return false
    end
    return Base.exec(
        [[UPDATE books SET path=NULL WHERE path LIKE ? ESCAPE '\';]],
        dir:gsub("([%%_\\])", "\\%1") .. "/%"
    ) ~= nil
end

--- 全部已登记路径（清缓存对账）
---@return { source_id: string, stable_id: string, path: string }[]
function BookDB.pathsAll()
    local result, nrows = Base.query([[SELECT source_id, stable_id, path FROM books WHERE path IS NOT NULL;]])
    local out = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            out[#out + 1] = {
                source_id = result[1][i],
                stable_id = result[2][i],
                path = result[3][i],
            }
        end
    end
    return out
end

--- 清空全部路径登记（清缓存）。
---@return boolean
function BookDB.clearPaths()
    return Base.exec([[UPDATE books SET path=NULL;]]) ~= nil
end

--- 按 (source_id, md5) 找已入库的行（本地源用内容摘要识别文件改名/移动）。
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

--- 改名/移动：把某本书的 stable_id 换成新值（本地源文件路径变化，身份仍由 md5 认定）。
--- category/series 由文件所在目录派生，随新位置一并刷新（传 nil 即清除）。
--- 本地源 path==stable_id，同步改写 path；所有书籍身份表一并联动，目录缓存直接失效。
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
    -- 身份必须同生共死：包事务，任何一步失败整体回滚
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
    Base.exec(ok and [[COMMIT;]] or [[ROLLBACK;]])
    return ok == true
end

--- 单列字符串查询 → string[]
---@param sql string
---@param ... any 绑定参数
---@return string[]
local function stringColumn(sql, ...)
    local result, nrows = Base.query(sql, ...)
    local out = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            out[i] = result[1][i]
        end
    end
    return out
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
        WHERE source_id=? AND in_library=1 ORDER BY stable_id;]], source_id)
end

--- 按源分页查询书库（图书馆直查数据库；排序与扫盘序一致 = stable_id）。
---@param source_id string
---@param opts { category: string|nil, series: string|nil, search: string|nil, limit: number|nil, offset: number|nil }|nil
---@return table[] rows, number count
function BookDB.listBySource(source_id, opts)
    opts = opts or {}
    local where = "b.source_id=? AND b.in_library=1"
    local args = { source_id }
    if opts.category and opts.category ~= "" then
        where = where .. " AND b.category=?"
        args[#args + 1] = opts.category
    end
    if opts.series and opts.series ~= "" then
        where = where .. " AND b.series=?"
        args[#args + 1] = opts.series
    end
    if opts.search and opts.search ~= "" then
        -- 转义 LIKE 通配符：用户输入的 % _ 是字面量
        where = where .. [[ AND (b.title LIKE ? ESCAPE '\' OR b.authors LIKE ? ESCAPE '\' OR b.stable_id LIKE ? ESCAPE '\')]]
        local like = "%" .. opts.search:gsub("([%%_\\])", "\\%1") .. "%"
        args[#args + 1] = like
        args[#args + 1] = like
        args[#args + 1] = like
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
    local sel = [[SELECT b.stable_id, b.title, b.authors,
                        COALESCE(p.fraction * 100, b.percent),
                        b.category, b.series, b.intro, b.cover, b.fetched_at
                   FROM books b LEFT JOIN pending_progress p
                     ON p.source_id=b.source_id AND p.stable_id=b.stable_id
                  WHERE ]] .. where .. " ORDER BY b.stable_id"
    if limit > 0 then
        sel = sel .. " LIMIT ? OFFSET ?"
        args[#args + 1] = limit
        args[#args + 1] = math.max(0, offset)
    end
    local result, nrows = Base.query(sel .. ";", unpack(args))
    local rows = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            rows[#rows + 1] = {
                source_id = source_id,
                stable_id = result[1][i],
                title = result[2][i],
                authors = result[3][i],
                percent = tonumber(result[4][i]) or 0,
                category = result[5][i],
                series = result[6][i],
                intro = result[7][i],
                cover = result[8][i],
                fetched_at = tonumber(result[9][i]) or 0,
            }
        end
    end
    return rows, total
end

--- 某源的书库分类列表（DISTINCT category，非空，字典序）。
---@param source_id string
---@return string[]
function BookDB.categoriesBySource(source_id)
    return stringColumn(
        [[SELECT DISTINCT category FROM books
          WHERE source_id=? AND in_library=1 AND category IS NOT NULL AND category<>''
          ORDER BY category;]],
        source_id
    )
end

--- 某源的书库系列列表（DISTINCT series，非空，字典序）。
---@param source_id string
---@return string[]
function BookDB.seriesBySource(source_id)
    return stringColumn(
        [[SELECT DISTINCT series FROM books
          WHERE source_id=? AND in_library=1 AND series IS NOT NULL AND series<>''
          ORDER BY series;]],
        source_id
    )
end

--- 按 (source_id, stable_id) 删除 books 行（不动 reading_stats），连带清目录缓存
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
    local payload, fetched_at = Base.rowexec(
        [[SELECT toc, toc_fetched_at FROM books
          WHERE source_id=? AND stable_id=? LIMIT 1;]],
        source_id, stable_id
    )
    if not payload then return nil end
    fetched_at = tonumber(fetched_at) or 0
    if max_age and os.time() - fetched_at >= max_age then
        return nil
    end
    return payload, fetched_at
end

--- 写入书籍目录缓存。
---@param source_id string
---@param stable_id string
---@param payload string
---@return boolean
function BookDB.setToc(source_id, stable_id, payload)
    return Base.exec(
        [[INSERT INTO books (source_id, stable_id, toc, toc_fetched_at)
          VALUES (?,?,?,?)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            toc=excluded.toc,
            toc_fetched_at=excluded.toc_fetched_at;]],
        source_id, stable_id, payload, os.time()
    ) ~= nil
end

--- 删除书籍目录缓存。
---@param source_id string
---@param stable_id string
---@return boolean
function BookDB.clearToc(source_id, stable_id)
    return Base.exec(
        [[UPDATE books SET toc=NULL, toc_fetched_at=0
          WHERE source_id=? AND stable_id=?;]],
        source_id, stable_id
    ) ~= nil
end

--- 读取全书阅读排版偏好（JSON 串）。
---@param source_id string
---@param stable_id string
---@return string|nil
function BookDB.getReaderPrefs(source_id, stable_id)
    local payload = Base.rowexec(
        [[SELECT reader_prefs FROM books WHERE source_id=? AND stable_id=? LIMIT 1;]],
        source_id,
        stable_id
    )
    return payload
end

--- 写入全书阅读排版偏好（JSON 串）。
---@param source_id string
---@param stable_id string
---@param payload string
---@return boolean
function BookDB.setReaderPrefs(source_id, stable_id, payload)
    return Base.exec(
        -- in_library=0：存排版偏好不代表这本书在书架上，
        -- 写成 1 会让对账隐藏过的书凭空回到书架。
        [[INSERT INTO books (source_id, stable_id, reader_prefs, in_library)
          VALUES (?, ?, ?, 0)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            reader_prefs=excluded.reader_prefs;]],
        source_id,
        stable_id,
        payload
    ) ~= nil
end

--- 清空全部书籍展示元数据（保留键与 md5）
---@return boolean
function BookDB.stripMeta()
    return Base.exec([[
UPDATE books SET
  title=NULL, authors=NULL, percent=0, category=NULL,
          series=NULL, intro=NULL, fetched_at=0;
]]) ~= nil
end

--- 清空 fetched_at 早于 before_ts 的书籍展示元数据
---@param before_ts number
---@return boolean
function BookDB.expireBefore(before_ts)
    before_ts = tonumber(before_ts) or 0
    return Base.exec([[
UPDATE books SET
  title=NULL, authors=NULL, percent=0, category=NULL,
  series=NULL, intro=NULL, fetched_at=0
WHERE fetched_at > 0 AND fetched_at < ?;
]], before_ts) ~= nil
end

return BookDB
