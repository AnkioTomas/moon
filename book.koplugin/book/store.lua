--[[--
本地书库门面（store）

  books/tocs/opens → utils.db（book.sqlite3）
  epub 落盘：.moon/cache/<source>/book/<bookKey>/

  filename + md5 一书一值；清文件缓存时保留身份行

@module koplugin.book.book.store
--]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local Paths = require("utils.paths")
local Db = require("utils.db")

local Store = {}

local META_TTL = 7 * 24 * 60 * 60
local TOC_TTL = 1 * 24 * 60 * 60
local LOCAL_BOOK_TTL = 90 * 24 * 60 * 60
local Contract = require("source.contract")

--- 路径末段文件名
---@param path string
---@return string|nil
local function basename(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return path:match("([^/\\]+)$") or path
end

--- 与 KOReader statistics 一致的内容 partialMD5（用于统计上报映射）
---@param path string
---@return string|nil
local function partialMd5(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local ok, util = pcall(require, "util")
    if not ok or not util or not util.partialMD5 then
        return nil
    end
    local mok, digest = pcall(util.partialMD5, path)
    if mok and type(digest) == "string" and digest ~= "" then
        return digest
    end
    return nil
end

--- fetched_at 是否已超过 ttl（fetched_at<=0 视为已过期）
---@param fetched_at number|nil
---@param ttl number
---@return boolean
local function isExpired(fetched_at, ttl)
    fetched_at = tonumber(fetched_at) or 0
    if fetched_at <= 0 then
        return true
    end
    return (os.time() - fetched_at) >= ttl
end

--- 从 Book 取 BookRef；缺 ref 直接失败
---@param book table|nil
---@return BookRef|nil
function Store.refOf(book)
    if type(book) ~= "table" or type(book.ref) ~= "table" then
        return nil
    end
    local ref = book.ref
    if type(ref.source_id) ~= "string" or ref.source_id == "" then
        return nil
    end
    if type(ref.stable_id) ~= "string" or ref.stable_id == "" then
        return nil
    end
    if type(ref.book_key) ~= "string" or ref.book_key == "" then
        return Contract.makeRef(ref.source_id, ref.stable_id)
    end
    return ref
end

--- bookKey = md5(sourceId .. ":" .. stableId)
---@param source_id string
---@param stable_id string
---@return string|nil
function Store.bookKey(source_id, stable_id)
    if type(stable_id) ~= "string" or stable_id == "" then
        return nil
    end
    if type(source_id) ~= "string" or source_id == "" then
        return nil
    end
    source_id = Paths.sanitizeSourceId(source_id)
    return md5(source_id .. ":" .. stable_id)
end

--- 从 Book.ref 取 book_key 与 stable_id
---@param book table
---@return string|nil book_key
---@return string|nil stable_id
---@return string|nil source_id
function Store.keyForBook(book)
    local ref = Store.refOf(book)
    if not ref then
        return nil, nil, nil
    end
    return ref.book_key, ref.stable_id, ref.source_id
end

--- 整本 epub 落盘路径
---@param book_key string
---@param source_id string
---@return string
function Store.bookFilePath(book_key, source_id)
    Paths.ensureBookWork(book_key, source_id)
    return Paths.bookWorkDir(book_key, source_id) .. "/book.epub"
end

--- 单章 epub 路径
---@param book_key string
---@param idx number|string
---@param source_id string
---@return string
function Store.chapterPath(book_key, idx, source_id)
    Paths.ensureBookWork(book_key, source_id)
    idx = tonumber(idx) or 0
    return Paths.bookWorkDir(book_key, source_id) .. "/" .. tostring(idx) .. ".epub"
end

--- 用 BookRef 返回整本路径
---@param ref BookRef
---@return string
function Store.bookPath(ref)
    return Store.bookFilePath(ref.book_key, ref.source_id)
end

--- 写入 books 元数据（刷新 fetched_at）；TTL 由 getMeta 判断
---@param book_key string
---@param meta table
---@param source_id string
---@return boolean
function Store.putMeta(book_key, meta, source_id)
    if type(book_key) ~= "string" or book_key == "" or type(meta) ~= "table" then
        return false
    end
    if type(source_id) ~= "string" or source_id == "" then
        return false
    end
    source_id = Paths.sanitizeSourceId(source_id)
    local stable = meta.stable_id or meta.filename
    if stable ~= nil then
        stable = tostring(stable)
    end
    local filename = meta.filename or stable
    local ok = Db.upsertBook({
        book_key = book_key,
        source_id = source_id,
        stable_id = stable or book_key,
        filename = filename and tostring(filename) or nil,
        md5 = meta.md5,
        title = meta.title or meta.bookName,
        authors = meta.authors or meta.author,
        percent = tonumber(meta.percent or meta.progressPercent or meta.progress) or 0,
        category = meta.category,
        favorite = meta.favorite,
        series = meta.series,
        intro = meta.intro or meta.description,
        fetched_at = os.time(),
    })
    if not ok then
        logger.warn("book.cache putMeta failed", book_key)
        return false
    end
    return true
end

--- 读 books 元数据；过 TTL（7 天）或 fetched_at=0 返回 nil。
---@param book_key string
---@return table|nil
function Store.getMeta(book_key)
    if type(book_key) ~= "string" or book_key == "" then
        return nil
    end
    Db.open()
    local data = Db.getBook(book_key)
    if not data then
        return nil
    end
    if isExpired(data.fetched_at, META_TTL) then
        return nil
    end
    local stable = data.stable_id or data.filename
    if stable ~= nil then
        stable = tostring(stable)
    end
    return {
        ref = stable and data.source_id and Contract.makeRef(data.source_id, stable) or nil,
        stable_id = stable,
        source_id = data.source_id,
        filename = data.filename,
        md5 = data.md5,
        title = data.title,
        authors = data.authors,
        percent = tonumber(data.percent) or 0,
        category = data.category,
        favorite = data.favorite,
        series = data.series,
        intro = data.intro,
        book_key = data.book_key or book_key,
        fetched_at = data.fetched_at,
    }
end

--- 写入 tocs（目录）；刷新 fetched_at
---@param book_key string
---@param toc table chapters 数组，或带 chapters/raw 的表
---@param source_id string
---@return boolean
function Store.putToc(book_key, toc, source_id)
    if type(book_key) ~= "string" or book_key == "" or type(toc) ~= "table" then
        return false
    end
    if type(source_id) ~= "string" or source_id == "" then
        return false
    end
    local ok = Db.putToc(book_key, source_id, {
        chapters = toc.chapters or toc,
        raw = toc.raw,
        fetched_at = os.time(),
    })
    if not ok then
        logger.warn("book.cache putToc failed", book_key)
        return false
    end
    return true
end

--- 读目录；过 TTL（1 天）则删行并返回 nil
---@param book_key string
---@return table|nil
function Store.getToc(book_key)
    if type(book_key) ~= "string" or book_key == "" then
        return nil
    end
    local data = Db.getToc(book_key)
    if not data then
        return nil
    end
    if isExpired(data.fetched_at, TOC_TTL) then
        Db.deleteToc(book_key)
        return nil
    end
    return data
end

--- 从契约 Book 抽出可入库的 meta 字段
---@param book table
---@return table|nil
local function metaFromBook(book)
    local ref = Store.refOf(book)
    if not ref then
        return nil
    end
    return {
        stable_id = ref.stable_id,
        filename = ref.stable_id,
        title = book.title,
        authors = book.authors,
        percent = tonumber(book.percent) or 0,
        category = book.category,
        favorite = book.favorite,
        series = book.series,
        intro = book.intro,
    }
end

--- 书架/列表记住单本
---@param book table
function Store.remember(book)
    local ref = Store.refOf(book)
    local meta = metaFromBook(book)
    if not ref or not meta then
        return
    end
    Store.putMeta(ref.book_key, meta, ref.source_id)
end

--- 批量 remember
---@param books table
function Store.rememberMany(books)
    if type(books) ~= "table" then
        return
    end
    for _, book in ipairs(books) do
        Store.remember(book)
    end
end

--- 查找带 title 的 meta
---@param book_key string
---@return table|nil
function Store.findMeta(book_key)
    local meta = Store.getMeta(book_key)
    if meta and meta.title then
        return meta
    end
    return nil
end

--- 长期持有：content md5 → filename（写在 books 行；清缓存不删）
---@param digest string
---@param filename string
---@param source_id string
function Store.rememberStatsMd5(digest, filename, source_id)
    if type(digest) ~= "string" or digest == "" then
        return
    end
    if type(filename) ~= "string" or filename == "" then
        return
    end
    if type(source_id) ~= "string" or source_id == "" then
        return
    end
    Db.setBookMd5(filename, digest, filename, source_id)
end

--- 统计上报用：全表 md5 → filename
---@return table<string, string>
function Store.md5FilenameMap()
    return Db.md5Map()
end

--- 单个 digest 反查远端 filename
---@param digest string
---@return string|nil
function Store.filenameByMd5(digest)
    return Db.filenameByMd5(digest)
end

--- 打开/下载后登记：写 opens；有 partialMD5 则更新 books.md5/filename
---@param path string 本地 epub 路径
---@param ref BookRef
---@param opts { chapter_idx: number|nil }|nil
function Store.touch(path, ref, opts)
    if not path or path == "" or type(ref) ~= "table" then
        return
    end
    if type(ref.book_key) ~= "string" or ref.book_key == "" then
        return
    end
    if type(ref.source_id) ~= "string" or ref.source_id == "" then
        return
    end
    opts = opts or {}
    local filename = ref.stable_id
    Db.upsertOpen(path, {
        book_key = ref.book_key,
        source_id = ref.source_id,
        stable_id = filename,
        chapter_idx = opts.chapter_idx,
        last_open = os.time(),
    })
    local digest = partialMd5(path)
    if digest and filename then
        Db.setBookMd5ByKey(ref.book_key, digest, filename)
        return
    end
    if digest then
        Db.setBookMd5ByKey(ref.book_key, digest, nil)
        return
    end
    if not filename then
        return
    end
    local row = Db.getBook(ref.book_key)
    if row then
        if row.filename == filename then
            return
        end
        Db.upsertBook({
            book_key = ref.book_key,
            source_id = row.source_id or ref.source_id,
            stable_id = row.stable_id or filename,
            filename = filename,
            md5 = row.md5,
            title = row.title,
            authors = row.authors,
            percent = row.percent,
            category = row.category,
            favorite = row.favorite,
            series = row.series,
            intro = row.intro,
            fetched_at = row.fetched_at or 0,
        })
        return
    end
    Db.upsertBook({
        book_key = ref.book_key,
        source_id = ref.source_id,
        stable_id = filename,
        filename = filename,
        fetched_at = 0,
    })
end

--- 本地路径 → opens 条目
---@param path string
---@return table|nil
function Store.entryFor(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local v = Db.getOpen(path)
    if not v then
        return nil
    end
    return {
        book_key = v.book_key,
        source_id = v.source_id,
        stable_id = v.stable_id,
        filename = v.stable_id,
        chapter_idx = v.chapter_idx,
        last_open = v.last_open,
    }
end

--- 本地路径 → book_key
---@param path string
---@return string|nil
function Store.bookKeyFor(path)
    local v = Store.entryFor(path)
    return v and v.book_key or nil
end

--- 本地路径 → 远端 stable_id
---@param path string
---@return string|nil
function Store.remoteFilename(path)
    local v = Store.entryFor(path)
    if v then
        if type(v.stable_id) == "string" and v.stable_id ~= "" then
            return v.stable_id
        end
        if v.book_key then
            local book = Db.getBook(v.book_key)
            if book and type(book.filename) == "string" and book.filename ~= "" then
                return book.filename
            end
        end
    end
    return basename(path)
end

--- 进度/面板用身份：完整 BookRef + chapter_idx
---@param path string
---@return { ref: BookRef, chapter_idx: number|nil }|nil
function Store.identityFor(path)
    local v = Store.entryFor(path)
    if not v or not v.stable_id then
        return nil
    end
    local source_id = v.source_id
    if (not source_id or source_id == "") and v.book_key then
        local book = Db.getBook(v.book_key)
        source_id = book and book.source_id
    end
    if not source_id or source_id == "" then
        return nil
    end
    return {
        ref = Contract.makeRef(source_id, v.stable_id),
        chapter_idx = v.chapter_idx,
    }
end

--- 递归删除目录
---@param path string
---@return boolean|nil
local function purgeDir(path)
    local ffiUtil = require("ffi/util")
    return ffiUtil.purgeDir(path)
end

--- 某书目录下所有 opens 的最近 last_open；没有则用目录 mtime
---@param book_dir string
---@param map table
---@return number
local function lastOpenForBookDir(book_dir, map)
    local latest = 0
    for path, v in pairs(map) do
        if type(path) == "string" and path:sub(1, #book_dir) == book_dir then
            local t = type(v) == "table" and tonumber(v.last_open) or 0
            if t > latest then
                latest = t
            end
        end
    end
    if latest > 0 then
        return latest
    end
    local attr = lfs.attributes(book_dir)
    return attr and (tonumber(attr.modification) or 0) or 0
end

--- 清理过期 meta/toc，并删掉连续 90 天未打开的书目录；顺带清失效 opens
---@return number 删除的目录/文件数
function Store.cleanupStale()
    Paths.ensureLayout()
    Db.open()
    local now = os.time()
    Db.expireBooksBefore(now - META_TTL)
    Db.deleteExpiredTocs(now - TOC_TTL)

    local map = Db.allOpens()
    local removed = 0
    local cache_root = Paths.cacheDir()
    if lfs.attributes(cache_root, "mode") ~= "directory" then
        return 0
    end

    for source_name in lfs.dir(cache_root) do
        if source_name ~= "." and source_name ~= ".." then
            local source_dir = cache_root .. "/" .. source_name
            if lfs.attributes(source_dir, "mode") == "directory" then
                local book_root = source_dir .. "/book"
                if lfs.attributes(book_root, "mode") == "directory" then
                    for name in lfs.dir(book_root) do
                        if name ~= "." and name ~= ".." then
                            local book_dir = book_root .. "/" .. name
                            local mode = lfs.attributes(book_dir, "mode")
                            if mode == "directory" then
                                local last_open = lastOpenForBookDir(book_dir, map)
                                if last_open > 0 and (now - last_open) >= LOCAL_BOOK_TTL then
                                    if purgeDir(book_dir) then
                                        removed = removed + 1
                                        logger.info("book cleaned stale book dir", book_dir)
                                    end
                                end
                            elseif mode == "file" then
                                local v = map[book_dir]
                                local last_open = type(v) == "table" and tonumber(v.last_open) or 0
                                if last_open <= 0 then
                                    local attr = lfs.attributes(book_dir)
                                    last_open = attr and (tonumber(attr.modification) or 0) or 0
                                end
                                if last_open > 0 and (now - last_open) >= LOCAL_BOOK_TTL then
                                    if pcall(os.remove, book_dir) then
                                        removed = removed + 1
                                        Db.deleteOpen(book_dir)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    for path, _ in pairs(map) do
        local mode = lfs.attributes(path, "mode")
        if mode ~= "file" and mode ~= "directory" then
            local parent = path:match("(.+)/[^/]+$")
            if not parent or lfs.attributes(parent, "mode") ~= "directory" then
                Db.deleteOpen(path)
            elseif mode ~= "file" then
                Db.deleteOpen(path)
            end
        end
    end
    return removed
end

--- 缓存占用字节：cache 目录文件 + book.sqlite3
---@return number
function Store.sizeBytes()
    local dir = Paths.cacheDir()
    local total = 0
    --- 递归累加目录下文件字节。
    ---@param path string
    local function walk(path)
        local mode = lfs.attributes(path, "mode")
        if mode == "file" then
            total = total + (tonumber(lfs.attributes(path, "size") or 0) or 0)
            return
        end
        if mode ~= "directory" then
            return
        end
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                walk(path .. "/" .. name)
            end
        end
    end
    if lfs.attributes(dir, "mode") == "directory" then
        walk(dir)
    end
    local db_file = Paths.dbPath()
    if lfs.attributes(db_file, "mode") == "file" then
        total = total + (tonumber(lfs.attributes(db_file, "size") or 0) or 0)
    end
    return total
end

--- 人类可读的缓存体积文案
---@return string
function Store.sizeLabel()
    local util = require("util")
    local n = Store.sizeBytes()
    if n <= 0 then
        return "0"
    end
    return util.getFriendlySize(n) or tostring(n)
end

--- 清空文件缓存 + tocs/opens；books 只剥 meta，保留 filename/md5
---@return boolean
function Store.clear()
    local ok_img, Image = pcall(require, "ui.components.image")
    if ok_img and Image and Image.abortPending then
        Image.abortPending()
    end
    local dir = Paths.cacheDir()
    if lfs.attributes(dir, "mode") == "directory" then
        local ffiUtil = require("ffi/util")
        local ok, err = ffiUtil.purgeDir(dir)
        if not ok then
            logger.warn("book cache purge failed", dir, err)
            return false
        end
    end
    Db.open()
    Db.clearTocs()
    Db.clearOpens()
    Db.stripBookMeta()
    Paths.ensureLayout()
    logger.info("book cache cleared", dir)
    return true
end

-- 模块加载时开库，触发一次性旧数据迁移
Db.open()

return Store
