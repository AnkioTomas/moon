--[[--
books 表：身份 + 书架成员（软删）+ 展示元数据 + 目录/排版本地缓存。

列职责：
  身份：source_id + stable_id（PK）、md5、path、inserted_at（0=仅身份行）
  成员：deleted（0=在架有效，1=软删/非成员）；sync_status（0 待上传，1 已同步）
  展示：title/authors/category/series/intro/cover
  扩展元数据：meta（JSON 对象，见 BookMeta；入库前由 normalizeMeta 规范成可直接展示的值）
  本地-only：reader_prefs、toc、toc_fetched_at、read_state、hidden（软删除：书留库不显示，远端同步不碰）
  进度真源在 pending_progress；本表不存 percent，进度禁止写回本表。

不变量：
  - touchPath / setReaderPrefs / setToc 新建行必须 deleted=1（只登记身份，禁止误上架）；
    upsert / upsertLocal 上架写 deleted=0 + sync_status=0。
  - inserted_at 只在首次上架时写一次：身份行（0）经 upsert / upsertLocal / 远端在架行上架时补写，
    之后不改；但源声明了权威加入时间（reconcile 的 inserted_at_from_row，如 Kavita 的
    lastChapterAddedUtc）时以源为准，否则整库同一次同步上架的行加入时间全相同，
    图书馆「最近添加」只能按 id 排。
  - 本地删除 = deleted=1 + sync_status=0（墓碑），推云端成功后 remove 撕墓碑（连同依附表）；本地上架推 addToShelf 后 markSynced。
  - 远端 upsert 遇本地脏行（sync_status=0）不盖 title/authors/category/series/intro 与 deleted。
  - meta 只经 setMeta 写（三种 upsert 写完顺带调），按键合并、从不清键：
    普通同步与详情只补缺的键；强制刷新（reconcile force）与本地写入（扫盘 / 刮削）覆盖传入的键。
    rating 是 { score, by } 整体，分数和来源不会拆开合并。
  - 书架脏位只在单条 push 成功时清，禁止整源盲清。
  - toc 是不透明 JSON，TTL 由调用方经 getToc(max_age) 解释，过期不删列。
跨表：只读 JOIN chapters（已下载口径）。改名 / 收编在同一事务里调核心依附表的 moveIdentity，
再经 utils.event 发 book_identity_changed 给 feature 的表；撕墓碑同理调 removeIdentity 再发 book_removed；
手动已读调 ProgressDB.markFinished。
别的表只经其模块函数改，本表不写别的表的 SQL。

@module koplugin.book.book.books_db
--]]

--- 路径解析出的阅读身份（Store.identityFor / ensureIdentity 返回值）。
---@class BookIdentity
---@field derived boolean|nil 派生文档沿用原书身份
---@field prefetch boolean|nil 后台预取请求
---@field source_id string 源标识（moon / wechat / jdread / local 等）
---@field stable_id string 源内稳定身份
---@field chapter_idx number|nil 章节文件时为章号；整本书为 nil
---@field book Book|nil books 表元数据行；刚登记/未入库时可能为内存行或 nil
---@field source BookSource|nil 属主源实例；仅 ensureIdentity（打开时）解析，identityFor 不挂
---@field ephemeral boolean|nil 属主源只读不记（订阅）：不存进度、不记统计；仅 ensureIdentity 设置
---@field title string|nil 展示书名；内存身份上可能有，books 行在 book 字段里
---@field cover string|nil 封面 URL（部分源直接挂在身份上）
---@field cover_url string|nil 封面 URL 别名

--- 对应表 books：身份列 + 展示元数据 + 软删成员 + sync_status。
---@class Book
---@field is_folder boolean|nil 文件夹视图中的目录条目
---@field dir string|nil 文件夹条目的完整路径
---@field read_at number|nil 最近阅读时间
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
---@field downloaded boolean|nil 展示用已下载标记（查询时按 downloadedClause 算出，非 books 列）
---@field download string|nil OPDS 等书城条目的下载地址，不入库
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
---@field hidden integer|nil 1=软删除（留库不显示）
---@field read_state integer|nil 0=未读且可自动标记，1=已读，2=用户强制未读
---@field reader_prefs string|nil 全书排版偏好 JSON（仅本地）
---@field toc string|nil 目录缓存 JSON（仅本地）
---@field toc_fetched_at integer|nil 目录缓存时间
---@field meta BookMeta|nil 扩展元数据（books.meta 解码）；写入时可传未规范的原始值

--- books.meta 的规范形态（normalizeMeta 的产物），缺的键即未知。
---@class BookMeta
---@field publisher string|nil 出版社
---@field published string|nil 出版日期：YYYY-MM 或 YYYY
---@field isbn string|nil ISBN：10 / 13 位，只含数字与 X
---@field language string|nil 语言主码，小写（zh / en / ja）
---@field words integer|nil 字数，> 0
---@field rating { score: number, by: string|nil }|nil 十分制一位小数 + 来源 id（weread / douban）
---@field detail_at integer|nil 最近一次拉单本详情的时间；详情页据此决定还要不要拉

--- 书籍详情（继承 Book 全部字段，含 intro）。
--- 详情页 / 悬浮菜单简介区使用；列表接口不必填 intro。
---@class BookDetail : Book

local DB = require("utils.db")
local Event = require("utils.event")
local JSON = require("json")
local Text = require("utils.text")
require("book.chapters_db")

local BookDB = {}

DB.schema("books", function()
    if not DB.exec([[
CREATE TABLE IF NOT EXISTS books (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL, md5 TEXT, title TEXT,
  authors TEXT, category TEXT, series TEXT, intro TEXT, cover TEXT,
  inserted_at INTEGER NOT NULL DEFAULT 0, path TEXT,
  deleted INTEGER NOT NULL DEFAULT 1, sync_status INTEGER NOT NULL DEFAULT 1,
  reader_prefs TEXT, toc TEXT, toc_fetched_at INTEGER NOT NULL DEFAULT 0,
  read_state INTEGER NOT NULL DEFAULT 0, meta TEXT,
  read_at INTEGER NOT NULL DEFAULT 0, hidden INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source_id, stable_id)
);
]]) then return false end
    local columns, nrows = DB.query("PRAGMA table_info(books);")
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
        { "meta", "meta TEXT" },
        -- 云端最近阅读时间（秒）：源书架快照给了才有，图书馆「最近阅读」排序用
        { "read_at", "read_at INTEGER NOT NULL DEFAULT 0" },
        -- 软删除：书留在库里（元数据、进度、标注都在），默认不在书架显示，只在「软删除」筛选里列出
        { "hidden", "hidden INTEGER NOT NULL DEFAULT 0" },
    }
    if columns then
        for i = 1, nrows do
            present[columns[2][i]] = true
        end
        for _idx, column in ipairs(missing) do
            if not present[column[1]]
                and not DB.exec("ALTER TABLE books ADD COLUMN " .. column[2] .. ";") then
                return false
            end
        end
        -- v0.0.8 及更早的加入时间在 fetched_at；v0.0.9 起迁移代码被删，直升的库从没迁过
        if present.fetched_at and not DB.exec([[UPDATE books SET inserted_at=fetched_at
            WHERE inserted_at=0 AND fetched_at>0;]]) then
            return false
        end
        -- 同理书架成员在 in_library；deleted 列刚补上（默认 1）时取反迁过来，否则整架消失。
        -- deleted 已存在的库不能再迁：之后的删除只记在 deleted 上，in_library 已过时。
        if present.in_library and not present.deleted and not DB.exec(
            [[UPDATE books SET deleted=CASE WHEN in_library=1 THEN 0 ELSE 1 END;]]) then
            return false
        end
    end
    -- 旧库的 idx_books_library 建在 in_library 上，同名 IF NOT EXISTS 不会重建。
    return DB.exec([[
DROP INDEX IF EXISTS idx_books_library;
CREATE INDEX IF NOT EXISTS idx_books_md5 ON books(source_id, md5);
CREATE INDEX IF NOT EXISTS idx_books_path ON books(path);
CREATE INDEX IF NOT EXISTS idx_books_library_v2 ON books(source_id, deleted, stable_id);
CREATE INDEX IF NOT EXISTS idx_books_sync ON books(source_id, sync_status);
]]) ~= nil
end)

--- 源给的原始元数据 → BookMeta；认不出的值丢掉，一项都没有返回 nil。
--- 源只做自己的语义换算（如微信千分制推荐值 → 十分），格式统一在这里。
---@param raw table|nil
---@return BookMeta|nil
local function normalizeMeta(raw)
    if type(raw) ~= "table" then return nil end
    local out = {}
    local publisher = type(raw.publisher) == "string" and Text.trim(raw.publisher) or ""
    if publisher ~= "" then out.publisher = publisher end
    -- 2022-01-01 00:00:00 / 2008-1 / 2008-01-01T00:00:00Z / 2008 → YYYY-MM 或 YYYY
    local year, month = tostring(raw.published or ""):match("^(%d%d%d%d)%D?(%d?%d?)")
    if year and tonumber(year) > 0 then
        month = tonumber(month)
        out.published = month and month >= 1 and month <= 12 and string.format("%s-%02d", year, month) or year
    end
    local isbn = (tostring(raw.isbn or ""):gsub("[^%dXx]", "")):upper()
    if #isbn == 10 or #isbn == 13 then out.isbn = isbn end
    -- zh-wr / zh_CN / EN → zh / en；整词（Chinese）不是语言码，不收
    local language = type(raw.language) == "string" and raw.language:lower():match("^%a+")
    if language and #language <= 3 then out.language = language end
    local words = math.floor(tonumber(raw.words) or 0)
    if words > 0 then out.words = words end
    local score = type(raw.rating) == "table" and tonumber(raw.rating.score)
    if score and score > 0 and score <= 10 then
        -- 1e-9：9.55 之类的浮点乘 10 后略小于 95.5，不补会舍成 9.5
        out.rating = { score = math.floor(score * 10 + 0.5 + 1e-9) / 10, by = raw.rating.by }
    end
    out.detail_at = tonumber(raw.detail_at)
    return next(out) and out or nil
end

--- 合并写 row.meta：overwrite 时传入的键覆盖已有值，否则只补缺的键；不清键。行不存在时什么都不做。
--- 书架对账逐行都会走到这里：合并后没变就不写（同步多是同一批元数据，空写上千行都在主线程）。
---@param row table 带 source_id / stable_id，meta 为原始元数据
---@param overwrite boolean|nil
---@return boolean
function BookDB.setMeta(row, overwrite)
    local incoming = normalizeMeta(row.meta)
    if not incoming then return true end
    local stored = DB.rowexec("SELECT meta FROM books WHERE source_id=? AND stable_id=? LIMIT 1;",
        row.source_id, row.stable_id)
    local merged = stored and JSON.decode(stored) or {}
    local changed = false
    for key, value in pairs(incoming) do
        if merged[key] == nil or (overwrite and JSON.encode(merged[key]) ~= JSON.encode(value)) then
            merged[key], changed = value, true
        end
    end
    if not changed then return true end
    return DB.exec("UPDATE books SET meta=? WHERE source_id=? AND stable_id=?;",
        JSON.encode(merged), row.source_id, row.stable_id) ~= nil
end

--- 插入或更新 books 行（本地可信写入：扫盘/本地登记），标脏待上传。
---@param row table
---@return boolean
function BookDB.upsert(row)
    local source_id = row.source_id
    local stable_id = row.stable_id
    local now = tonumber(row.inserted_at) or os.time()
    return DB.exec(
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
            inserted_at=CASE WHEN books.inserted_at=0 THEN excluded.inserted_at ELSE books.inserted_at END,
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
    ) ~= nil and BookDB.setMeta(row, true)
end

--- 秒级时间戳；毫秒值（> 1e11）折成秒，无效为 0。
---@param value any
---@return integer
local function readAt(value)
    local n = tonumber(value) or 0
    if n > 1e11 then n = n / 1000 end
    return n > 0 and math.floor(n) or 0
end

--- 远端书架行写入。本地脏行（sync_status=0）保留展示字段。
---@param row table
---@param overwrite boolean|nil 用户强制刷新：meta 覆盖已有键，否则只补缺
---@param dated boolean|nil 快照行自带权威加入时间：为真且 row.inserted_at 有值时覆盖已有的占位值
--- row.read_at：云端最近阅读时间（秒），只增不减。
---@return boolean
function BookDB.upsertRemote(row, overwrite, dated)
    local source_id = row.source_id
    local stable_id = row.stable_id
    local has_membership = row.deleted ~= nil
    local deleted = 1
    if row.deleted ~= nil then
        deleted = (row.deleted == true or tonumber(row.deleted) == 1) and 1 or 0
    end
    -- 源给了加入时间才算权威；行里没带日期的仍走「只在 0 时补写」。
    local authored = dated == true and row.inserted_at ~= nil
    local now = deleted == 0 and (tonumber(row.inserted_at) or os.time()) or 0
    return DB.exec(
        [[INSERT INTO books (
            source_id, stable_id, md5, title, authors, category,
            series, intro, cover, inserted_at, path, deleted, sync_status, read_at
          ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,1,?)
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
            read_at=MAX(books.read_at, excluded.read_at),
            inserted_at=CASE
                WHEN excluded.deleted=0 AND (?=1 OR books.inserted_at=0)
                    THEN excluded.inserted_at
                ELSE books.inserted_at END,
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
        deleted, readAt(row.read_at),
        authored and 1 or 0,
        has_membership and 1 or 0, has_membership and 1 or 0
    ) ~= nil and BookDB.setMeta(row, overwrite)
end

--- 一个事务写入一批远端行（逐行语义同 upsertRemote）；任一行失败整批回滚。
---@param rows table[]
---@return boolean
function BookDB.upsertRemoteMany(rows)
    return DB.transaction(function()
        for _idx, row in ipairs(rows) do
            if not BookDB.upsertRemote(row) then return false end
        end
        return true
    end) == true
end

--- 用户编辑/刮削写入展示元数据。新行与复活的墓碑标脏；已有行保留 sync_status
--- （纯本地扫盘 reconcile 只下架已同步行），有远端的源自己标脏上行（local WebDAV 见 pushBookAsync）。
---@param row table
---@return boolean
function BookDB.upsertLocal(row)
    local source_id = row.source_id
    local stable_id = row.stable_id
    local now = tonumber(row.inserted_at) or os.time()
    return DB.exec(
        [[INSERT INTO books (
            source_id, stable_id, title, authors, category,
            series, intro, inserted_at, deleted, sync_status
          ) VALUES (?,?,?,?,?,?,?,?,0,0)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            title=excluded.title, authors=excluded.authors,
            category=excluded.category,
            series=excluded.series, intro=excluded.intro,
            inserted_at=CASE WHEN books.inserted_at=0 THEN excluded.inserted_at ELSE books.inserted_at END,
            deleted=0,
            sync_status=CASE WHEN books.deleted=1 THEN 0 ELSE books.sync_status END;]],
        source_id, stable_id, row.title, row.authors,
        row.category, row.series, row.intro, now
    ) ~= nil and BookDB.setMeta(row, true)
end

--- 远端书架快照入库：先把当前在架标软删，再 upsert 远端成员。
---@param source_id string
---@param books table[]
---@param opts { clear_missing_paths: boolean|nil, force: boolean|nil, allow_empty: boolean|nil, inserted_at_from_row: boolean|nil }|nil
---   force：用户强制刷新，快照里的 meta 覆盖已有键；
---   allow_empty：空快照也照常下架（手动刷新 / 本地扫盘）；
---   inserted_at_from_row：行自带权威加入时间（源提供），覆盖本地占位值
---@return boolean ok
---@return integer|nil hidden 原本在架、本次快照里缺席的行数
function BookDB.reconcile(source_id, books, opts)
    opts = opts or {}
    -- 自动同步拿到空书架多半是接口抖动 / 会话失效：不下架，免得书架整个变空；用户手动刷新才认空快照。
    if #books == 0 and not opts.allow_empty then
        return true, 0
    end
    local hidden = DB.transaction(function()
        local incoming = {}
        for _idx, book in ipairs(books) do
            if book.stable_id ~= nil then incoming[tostring(book.stable_id)] = true end
        end
        local count = 0
        for _idx, stable_id in ipairs(BookDB.libraryStableIdsBySource(source_id)) do
            if not incoming[stable_id] then count = count + 1 end
        end
        local deactivate = opts.clear_missing_paths
            and [[UPDATE books SET deleted=1, path=NULL
                WHERE source_id=? AND deleted=0 AND sync_status=1;]]
            or [[UPDATE books SET deleted=1
                WHERE source_id=? AND deleted=0 AND sync_status=1;]]
        if not DB.exec(deactivate, source_id) then return nil end
        for _idx, row in ipairs(books) do
            local copy = {}
            for k, v in pairs(row) do copy[k] = v end
            copy.source_id = source_id
            copy.deleted = 0
            if not BookDB.upsertRemote(copy, opts.force, opts.inserted_at_from_row) then return nil end
        end
        return count
    end)
    if hidden then return true, hidden end
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
        return DB.exec([[UPDATE books SET deleted=1, path=NULL, sync_status=0
            WHERE source_id=? AND stable_id=?;]], source_id, stable_id) ~= nil
    end
    return DB.exec([[UPDATE books SET deleted=?, sync_status=0
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
    local result, nrows = DB.query(sql, ...)
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
    "source_id, stable_id, md5, title, authors, category, series, intro, cover, inserted_at, path, deleted, sync_status, read_state, meta, hidden"

--- rowexec 位置参数 → Book 表
---@return Book|nil
local function rowToBook(source_id_r, stable_id_r, digest, title, authors, category, series, intro, cover, inserted_at, path, deleted, sync_status, read_state, meta, hidden)
    if not source_id_r then
        return nil
    end
    local del = tonumber(deleted) or 1
    local book = {
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
        hidden = tonumber(hidden) or 0,
        percent = 0,
        meta = meta and JSON.decode(meta) or nil,
    }
    return book
end

--- DB.query 列式结果的第 i 行 → Book
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
    return rowToBook(DB.rowexec(
        "SELECT " .. COLUMNS .. " FROM books WHERE source_id=? AND stable_id=? LIMIT 1;",
        source_id,
        stable_id
    ))
end

--- 全部源的在架书（deleted=0）。
---@return Book[]
function BookDB.listLibrary()
    local result, nrows = DB.query("SELECT " .. COLUMNS .. " FROM books WHERE deleted=?;", 0)
    local out = {}
    for i = 1, nrows do out[i] = bookAt(result, i) end
    return out
end

--- 批量取 books 行，避免统计/列表场景的 N+1 查询。
---@param source_id string
---@param stable_ids string[]
---@return table<string, Book>
function BookDB.getMany(source_id, stable_ids)
    local ids, seen = {}, {}
    for _idx, stable_id in ipairs(stable_ids) do
        if not seen[stable_id] then
            seen[stable_id] = true
            ids[#ids + 1] = stable_id
        end
    end
    if #ids == 0 then return {} end

    local out = {}
    for start = 1, #ids, 500 do
        local finish = math.min(start + 499, #ids)
        local result, nrows = DB.query(
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
    return rowToBook(DB.rowexec(
        "SELECT " .. COLUMNS .. " FROM books WHERE path=? LIMIT 1;",
        path
    ))
end

--- 清空某源全部书的分类 / 系列（本地源关闭「按文件夹分类」时，丢掉由目录派生的旧值）。
---@param source_id string
---@return boolean
function BookDB.clearCategories(source_id)
    return DB.exec("UPDATE books SET category=NULL, series=NULL WHERE source_id=?;", source_id) ~= nil
end

--- 文件落地后登记物理路径。
--- 行不存在时补身份行：deleted=1（非书架成员）、sync_status=1。
---@param source_id string
---@param stable_id string
---@param path string
---@return boolean
function BookDB.touchPath(source_id, stable_id, path)
    return DB.exec(
        [[INSERT INTO books (source_id, stable_id, inserted_at, path, deleted, sync_status)
          VALUES (?,?,0,?,1,1)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            path=excluded.path;]],
        source_id,
        stable_id,
        path
    ) ~= nil
end

--- 登记了物理路径的行。纯本地书除外：它的 path 即 stable_id，由扫盘负责；
--- WebDAV 书（同属 local 源）的 path 是下载副本，照样校验。
---@param source_id string|string[]
---@return { source_id: string, stable_id: string, path: string }[]
function BookDB.pathsBySource(source_id)
    local where, args = DB.sourceClause("source_id", source_id)
    local result, nrows = DB.query(
        "SELECT source_id, stable_id, path FROM books WHERE " .. where
            .. " AND NOT (source_id='local' AND path=stable_id) AND path IS NOT NULL AND path<>'';",
        unpack(args)
    )
    local out = {}
    for i = 1, nrows do
        out[i] = { source_id = result[1][i], stable_id = result[2][i], path = result[3][i] }
    end
    return out
end

--- 一个事务撤掉失效的路径登记；path 已被改写（校验期间重新下载）的行不动。
---@param rows { source_id: string, stable_id: string, path: string }[]
---@return boolean
function BookDB.clearPaths(rows)
    return DB.transaction(function()
        for _idx, row in ipairs(rows) do
            if not DB.exec(
                [[UPDATE books SET path=NULL WHERE source_id=? AND stable_id=? AND path=?;]],
                row.source_id, row.stable_id, row.path
            ) then
                return false
            end
        end
        return true
    end) == true
end

--- 手动标记已读/未读。
--- 已读：read_state=1，同一事务里进度表补 100% 待上传进度。
--- 未读：read_state=2；不回退进度。
---@param source_id string
---@param stable_id string
---@param is_read boolean
---@return boolean
function BookDB.setRead(source_id, stable_id, is_read)
    if not is_read then
        return DB.exec([[UPDATE books SET read_state=2
            WHERE source_id=? AND stable_id=?;]],
            source_id, stable_id) ~= nil
    end
    return DB.transaction(function()
        return DB.exec([[UPDATE books SET read_state=1
            WHERE source_id=? AND stable_id=?;]],
            source_id, stable_id)
            -- progress_db 顶层 require 本模块，只能在这里延迟加载。
            and require("book.progress_db").markFinished(source_id, stable_id)
    end) == true
end

--- 自动标记已读；只允许更新从未被用户强制标为未读的书。
---@param source_id string
---@param stable_id string
---@return boolean
function BookDB.markReadAutomatically(source_id, stable_id)
    return DB.exec([[UPDATE books SET read_state=1
        WHERE source_id=? AND stable_id=? AND read_state=0;]],
        source_id, stable_id) ~= nil
end

--- 完整读到 100% 后标记已读；完成事实优先于手动未读。
---@param source_id string
---@param stable_id string
---@return boolean
function BookDB.markReadComplete(source_id, stable_id)
    return DB.exec([[UPDATE books SET read_state=1
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
    return DB.exec(
        [[UPDATE books SET path=NULL WHERE path LIKE ? ESCAPE '\';]],
        dir:gsub("([%%_\\])", "\\%1") .. "/%"
    ) ~= nil
end

--- 按 (source_id, md5) 列出在架行的 stable_id（不含墓碑：删掉的书不能被同内容的新文件收编复活）。
--- 同内容副本可以并存，由调用方挑真正被移走的那一行。
---@param source_id string
---@param md5 string
---@return string[]
function BookDB.stableIdsByMd5(source_id, md5)
    return stringColumn([[SELECT stable_id FROM books
          WHERE source_id=? AND md5=? AND deleted=0
          ORDER BY inserted_at ASC, stable_id ASC;]], source_id, md5)
end

--- 挂在书身份上的核心表模块；note / progress / stats 顶层 require 本模块，只能延迟加载。
local IDENTITY_MODULES = {
    "book.chapters_db", "book.note_db", "book.progress_db", "book.stats_db", "book.review_cache", "ai.summary_db",
}

--- 依附表跟着迁身份：先核心表，再发事件给 feature 的表。须在调用方事务内。
---@return boolean
local function moveIdentity(source_id, old_stable_id, new_stable_id, merge)
    for _idx, name in ipairs(IDENTITY_MODULES) do
        if not require(name).moveIdentity(source_id, old_stable_id, new_stable_id, merge) then return false end
    end
    return Event.emit("book_identity_changed", source_id, old_stable_id, new_stable_id, merge)
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
    return DB.transaction(function()
        return DB.exec(
            [[UPDATE books SET stable_id=?, category=?, series=?, path=? WHERE source_id=? AND stable_id=?;]],
            new_stable_id, category, series, new_stable_id, source_id, old_stable_id
        ) and moveIdentity(source_id, old_stable_id, new_stable_id, false)
    end) == true
end

--- 把旧身份并入新身份，并登记新身份的物理路径（WebDAV 镜像收编本地目录里的绝对路径身份）。
--- 新身份不存在或只是删除墓碑：旧行整行改名（带走元数据与书架状态）；新身份已在书架：丢弃旧行。
--- 依附表以 merge=true 各自迁移（见 DB.moveIdentity）。
---@param source_id string
---@param old_stable_id string
---@param new_stable_id string
---@param path string
---@return boolean
function BookDB.adoptStableId(source_id, old_stable_id, new_stable_id, path)
    return DB.transaction(function()
        return DB.exec(
            [[DELETE FROM books WHERE source_id=? AND stable_id=? AND deleted=1;]],
            source_id, new_stable_id
        ) and DB.exec(
            [[UPDATE OR IGNORE books SET stable_id=? WHERE source_id=? AND stable_id=?;]],
            new_stable_id, source_id, old_stable_id
        ) and DB.exec(
            [[DELETE FROM books WHERE source_id=? AND stable_id=?;]],
            source_id, old_stable_id
        ) and DB.exec(
            [[UPDATE books SET path=? WHERE source_id=? AND stable_id=?;]],
            path, source_id, new_stable_id
        ) and moveIdentity(source_id, old_stable_id, new_stable_id, true)
    end) == true
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
    local result, nrows = DB.query(
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
    return DB.exec([[UPDATE books SET sync_status=1
        WHERE source_id=? AND stable_id=?;]], source_id, stable_id) ~= nil
end

--- 批量清脏（单事务）。
---@param source_id string
---@param stable_ids string[]
---@return boolean
function BookDB.markSyncedMany(source_id, stable_ids)
    return DB.transaction(function()
        for _idx, stable_id in ipairs(stable_ids) do
            if not BookDB.markSynced(source_id, stable_id) then return nil end
        end
        return true
    end) ~= nil
end

--- 「有效身份」条件：在架，或**非书架成员但仍是有效身份行**。
--- 远端源会给非书架行建身份（如 Kavita 多卷 series 的卷行：读书进度记在卷行上，
--- 它故意不上架）；墓碑（deleted=1 + sync_status=0，本地删了等推云端）不算。
--- 已知取舍：远端对账下架的行也会落成「非成员身份行」，它会连同进度留在最近阅读里，
--- 直到云端删除被确认、行被撕掉。
--- 本地源例外：它的「远端」就是磁盘，下架即文件没了（path 已清空），没有可读的东西，不能留进度行。
---@param alias string|nil books 表别名，缺省 b
---@return string SQL 片段
function BookDB.readableClause(alias)
    alias = alias or "b"
    return "(" .. alias .. ".deleted=0 OR (" .. alias .. ".sync_status=1 AND NOT ("
        .. alias .. ".source_id='local' AND " .. alias .. ".path IS NULL)))"
end

--- 已下载条件（唯一口径）：章节源从当前阅读章（pending_progress.chapter_idx，无则第 1 章）起，
--- 登记的章节连续无缺口（当前章已缓存，往后去重章数 = 最大章号 - 当前章 + 1），之前的章不管；
--- 其余源有 path。不看目录长度：连载更新、目录缓存过期都不该把已缓存的书变成未下载。
---@param chapter_sources string[] 章节型源 id
--- SQL 片段里 books 表别名必须是 b。
---@param args table 追加绑定参数
---@return string
function BookDB.downloadedClause(chapter_sources, args)
    local is_chapter = DB.sourceClause("b.source_id", chapter_sources, args)
    local cur = "COALESCE((SELECT p.chapter_idx FROM pending_progress p"
        .. " WHERE p.source_id=b.source_id AND p.stable_id=b.stable_id), 1)"
    return "(CASE WHEN " .. is_chapter .. " THEN COALESCE((SELECT MIN(c.chapter_idx) = " .. cur
        .. " AND COUNT(DISTINCT c.chapter_idx) = MAX(c.chapter_idx) - MIN(c.chapter_idx) + 1"
        .. " FROM chapters c WHERE c.source_id=b.source_id AND c.stable_id=b.stable_id"
        .. " AND c.chapter_idx >= " .. cur .. "), 0)"
        .. " ELSE COALESCE(b.path, '')<>'' END)"
end

--- 单本是否已下载（口径同 downloadedClause）。
---@param source_id string
---@param stable_id string
---@param chapter boolean 属主源是否章节型
---@return boolean
function BookDB.isDownloaded(source_id, stable_id, chapter)
    local args = {}
    local clause = BookDB.downloadedClause(chapter and { source_id } or {}, args)
    args[#args + 1] = source_id
    args[#args + 1] = stable_id
    return tonumber(DB.rowexec(
        "SELECT " .. clause .. " FROM books b WHERE b.source_id=? AND b.stable_id=? LIMIT 1;",
        unpack(args)
    )) == 1
end

--- 书架按某文本列（category / series / authors）聚合册数；空值归到 ''，排在最后
---@param column "category"|"series"|"authors" 同时是返回行的键
---@param source_id string|string[]
---@return table[]
function BookDB.countsBy(column, source_id)
    local where, args = DB.sourceClause("source_id", source_id)
    local bucket = "CASE WHEN " .. column .. " IS NULL OR " .. column .. "='' THEN '' ELSE " .. column .. " END"
    local result, nrows = DB.query(
        "SELECT " .. bucket .. ", COUNT(*) FROM books WHERE " .. where .. " AND deleted=0 AND hidden=0"
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

--- 范围内按 source_id 聚合册数
---@param source_id string|string[]
---@return { source_id: string, count: integer }[]
function BookDB.sourceCountsBySource(source_id)
    local where, args = DB.sourceClause("source_id", source_id)
    local result, nrows = DB.query(
        [[SELECT source_id, COUNT(*)
          FROM books
          WHERE ]] .. where .. [[ AND deleted=0 AND hidden=0
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
    local where, args = DB.sourceClause("source_id", source_id)
    local result, nrows = DB.query(
        [[SELECT CASE
                   WHEN read_state=1 THEN 'read'
                   ELSE 'unread'
                 END,
                 COUNT(*)
          FROM books
          WHERE ]] .. where .. [[ AND deleted=0 AND hidden=0
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

--- 某源书架已下载册数。
---@param source_id string|string[]
---@param chapter_sources string[] 章节型源 id
---@return integer
function BookDB.downloadedCountBySource(source_id, chapter_sources)
    local where, args = DB.sourceClause("b.source_id", source_id)
    where = where .. " AND b.deleted=0 AND b.hidden=0 AND " .. BookDB.downloadedClause(chapter_sources, args)
    return tonumber(DB.rowexec("SELECT COUNT(*) FROM books b WHERE " .. where .. ";", unpack(args))) or 0
end

--- 软删除书架数（deleted=0 且 hidden=1）。
---@param source_id string|string[]
---@return integer
function BookDB.hiddenCountBySource(source_id)
    local where, args = DB.sourceClause("source_id", source_id)
    return tonumber(DB.rowexec("SELECT COUNT(*) FROM books WHERE " .. where .. " AND deleted=0 AND hidden=1;",
        unpack(args))) or 0
end

--- 软删除 / 恢复：只改本地 hidden 列，不碰同步状态。
---@param source_id string
---@param stable_id string
---@param hidden boolean
---@return boolean
function BookDB.setHidden(source_id, stable_id, hidden)
    return DB.exec([[UPDATE books SET hidden=? WHERE source_id=? AND stable_id=?;]],
        hidden and 1 or 0, source_id, stable_id) ~= nil
end

--- 撕墓碑：远端确认删除后删掉 books 行，依附表（核心表 + 经 book_removed 的 feature 表）一并清掉。
--- 只删墓碑（deleted=1）：推送期间用户又把书加回书架时，不能把重新上架的书连同进度删掉。
--- 没有墓碑可撕也算成功。
---@param source_id string
---@param stable_id string
---@return boolean
function BookDB.remove(source_id, stable_id)
    return DB.transaction(function()
        if not DB.exec([[DELETE FROM books WHERE source_id=? AND stable_id=? AND deleted=1;]],
                source_id, stable_id) then
            return false
        end
        if (tonumber(DB.rowexec("SELECT changes();")) or 0) == 0 then return true end
        for _idx, name in ipairs(IDENTITY_MODULES) do
            if not require(name).removeIdentity(source_id, stable_id) then return false end
        end
        return Event.emit("book_removed", source_id, stable_id)
    end) == true
end

--- 读取书籍目录缓存；max_age 秒内才命中。
---@param source_id string
---@param stable_id string
---@param max_age number|nil
---@return string|nil, number|nil
function BookDB.getToc(source_id, stable_id, max_age)
    local payload, toc_at = DB.rowexec(
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
    return DB.exec(
        [[INSERT INTO books (source_id, stable_id, toc, toc_fetched_at, deleted, sync_status)
          VALUES (?,?,?,?,1,1)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            toc=excluded.toc,
            toc_fetched_at=excluded.toc_fetched_at;]],
        source_id, stable_id, payload, os.time()
    ) ~= nil
end

--- 清除书籍目录缓存。
---@param source_id string
---@param stable_id string
---@return boolean
function BookDB.clearToc(source_id, stable_id)
    return DB.exec(
        [[UPDATE books SET toc=NULL, toc_fetched_at=0 WHERE source_id=? AND stable_id=?;]],
        source_id, stable_id
    ) ~= nil
end

--- 读取全书阅读排版偏好（JSON 串）。
---@param source_id string
---@param stable_id string
---@return string|nil
function BookDB.getReaderPrefs(source_id, stable_id)
    return (DB.rowexec(
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
    return DB.exec(
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
