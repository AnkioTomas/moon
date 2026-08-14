--[[--
本地书库门面（store）

  books/tocs/opens → utils.db.*（book.sqlite3）
  epub 落盘：.moon/cache/<source>/book/<bookKey>/

  filename + md5 一书一值；清文件缓存时保留身份行

@module koplugin.book.book.store
--]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local Paths = require("utils.paths")
local DbBase = require("utils.db.base")
local BookDB = require("utils.db.book")
local TocDB = require("utils.db.toc")
local OpenDB = require("utils.db.open")
local DbQueue = require("utils.db.queue")
local Task = require("utils.task")

local Store = {}

local META_TTL = 7 * 24 * 60 * 60
local TOC_TTL = 1 * 24 * 60 * 60
local LOCAL_BOOK_TTL = 90 * 24 * 60 * 60
local BookRef = require("types.book").BookRef

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
    return book.ref
end

--- 从远端标识提取受支持的书籍扩展名。
---@param stable_id string|nil
---@return string
local function bookExtension(stable_id)
    local ext = type(stable_id) == "string" and stable_id:match("%.([%w]+)$") or nil
    ext = ext and string.lower(ext) or nil
    local supported = {
        epub = true,
        pdf = true,
        cbz = true,
        cbr = true,
        mobi = true,
        azw3 = true,
        txt = true,
    }
    return ext and supported[ext] and ext or "epub"
end

--- 整本书落盘路径；保留远端格式以供 KOReader 选择对应文档引擎。
---@param book_key string
---@param source_id string
---@param stable_id string|nil
---@return string
function Store.bookFilePath(book_key, source_id, stable_id)
    Paths.ensureBookWork(book_key, source_id)
    return Paths.bookWorkDir(book_key, source_id) .. "/book." .. bookExtension(stable_id)
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

--- 写入 books 元数据（刷新 fetched_at）；TTL 由 getMeta 判断。
--- 必须在 Task 子进程内调用（通过 putMetaAsync 间接使用）。
---@param book_key string
---@param meta table
---@param source_id string
---@return boolean
local function putMetaSync(book_key, meta, source_id)
    if type(book_key) ~= "string" or book_key == "" or type(meta) ~= "table" then
        return false
    end
    if type(source_id) ~= "string" or source_id == "" then
        return false
    end
    local stable = meta.stable_id or meta.filename
    if stable ~= nil then
        stable = tostring(stable)
    end
    local filename = meta.filename or stable
    local ok = BookDB.upsert({
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

--- 异步写入 books 元数据（fire-and-forget，不堵 UI）
---@param book_key string
---@param meta table
---@param source_id string
function Store.putMetaAsync(book_key, meta, source_id)
    if type(book_key) ~= "string" or book_key == "" or type(meta) ~= "table" then
        return
    end
    if type(source_id) ~= "string" or source_id == "" then
        return
    end
    local stable = meta.stable_id or meta.filename
    if stable ~= nil then
        stable = tostring(stable)
    end
    local filename = meta.filename or stable
    local payload = {
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
    }
    DbQueue.run(function()
        local BookDB = require("utils.db.book")
        local ok = BookDB.upsert(payload)
        if not ok then
            logger.warn("book.cache putMetaAsync failed", book_key)
        end
    end)
end

--- 写入 books 元数据（已废弃，请使用 putMetaAsync）
---@deprecated 使用 Store.putMetaAsync 代替
---@param book_key string
---@param meta table
---@param source_id string
---@return boolean
function Store.putMeta(book_key, meta, source_id)
    return putMetaSync(book_key, meta, source_id)
end

--- 读 books 元数据；过 TTL（7 天）或 fetched_at=0 返回 nil。
--- 必须在 Task 子进程内调用（通过 getMetaAsync 间接使用）。
---@param book_key string
---@return table|nil
local function getMetaSync(book_key)
    if type(book_key) ~= "string" or book_key == "" then
        return nil
    end
    DbBase.open()
    local data = BookDB.get(book_key)
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
        ref = stable and data.source_id and BookRef.new(data.source_id, stable) or nil,
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

--- 异步读 books 元数据；回调 fun(meta: table|nil)
---@param book_key string
---@param cb fun(meta: table|nil)
---@return { cancel: fun() }
function Store.getMetaAsync(book_key, cb)
    if type(book_key) ~= "string" or book_key == "" then
        UIManager:nextTick(function()
            cb(nil)
        end)
        return { cancel = function() end }
    end

    local cancelled = false
    local job = { cancel = function() cancelled = true end }

    UIManager:nextTick(function()
        if cancelled then
            return
        end
        local meta = getMetaSync(book_key)
        cb(meta)
    end)

    return job
end

--- 同步读 books 元数据（仅内部使用，必须在 Task 子进程内调用）。
--- 外部调用请使用 Store.getMetaAsync。
---@deprecated 使用 Store.getMetaAsync 代替
---@param book_key string
---@return table|nil
function Store.getMeta(book_key)
    return getMetaSync(book_key)
end

--- 异步写入 tocs（目录）；fire-and-forget，不堵 UI
---@param book_key string
---@param toc table chapters 数组，或带 chapters/raw 的表
---@param source_id string
function Store.putTocAsync(book_key, toc, source_id)
    if type(book_key) ~= "string" or book_key == "" or type(toc) ~= "table" then
        return
    end
    if type(source_id) ~= "string" or source_id == "" then
        return
    end
    local chapters = toc.chapters or toc
    local raw = toc.raw
    local fetched_at = os.time()
    DbQueue.run(function()
        local TocDB = require("utils.db.toc")
        local ok = TocDB.put(book_key, source_id, {
            chapters = chapters,
            raw = raw,
            fetched_at = fetched_at,
        })
        if not ok then
            logger.warn("book.cache putTocAsync failed", book_key)
        end
    end)
end

--- 写入 tocs（目录）；刷新 fetched_at（已废弃，请使用 putTocAsync）
---@deprecated 使用 Store.putTocAsync 代替
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
    local ok = TocDB.put(book_key, source_id, {
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
    local data = TocDB.get(book_key)
    if not data then
        return nil
    end
    if isExpired(data.fetched_at, TOC_TTL) then
        TocDB.delete(book_key)
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

--- 书架/列表记住单本（异步，不堵 UI）
---@param book table
function Store.remember(book)
    local ref = Store.refOf(book)
    local meta = metaFromBook(book)
    if not ref or not meta then
        return
    end
    Store.putMetaAsync(ref.book_key, meta, ref.source_id)
end

--- 批量 remember
---@param books table
function Store.rememberMany(books)
    if type(books) ~= "table" or #books == 0 then
        return
    end
    local payload = {}
    for _, book in ipairs(books) do
        local ref = Store.refOf(book)
        local meta = metaFromBook(book)
        if ref and meta then
            payload[#payload + 1] = {
                book_key = ref.book_key,
                source_id = ref.source_id,
                stable_id = ref.stable_id,
                filename = meta.filename or ref.stable_id,
                md5 = meta.md5,
                title = meta.title,
                authors = meta.authors,
                percent = meta.percent,
                category = meta.category,
                favorite = meta.favorite,
                series = meta.series,
                intro = meta.intro,
                fetched_at = os.time(),
            }
        end
    end
    if #payload == 0 then
        return
    end
    DbQueue.run(function()
        local BookDB = require("utils.db.book")
        for i = 1, #payload do
            BookDB.upsert(payload[i])
        end
    end)
end

--- 异步查找带 title 的 meta；回调 fun(meta: table|nil)
---@param book_key string
---@param cb fun(meta: table|nil)
---@return { cancel: fun() }
function Store.findMetaAsync(book_key, cb)
    return Store.getMetaAsync(book_key, function(meta)
        if meta and meta.title then
            cb(meta)
        else
            cb(nil)
        end
    end)
end

--- 查找带 title 的 meta（已废弃，请使用 findMetaAsync）
---@deprecated 使用 Store.findMetaAsync 代替
---@param book_key string
---@return table|nil
function Store.findMeta(book_key)
    local meta = Store.getMeta(book_key)
    if meta and meta.title then
        return meta
    end
    return nil
end

--- 异步打开/下载后登记（fire-and-forget）
---@param path string 本地 epub 路径
---@param ref BookRef
---@param opts { chapter_idx: number|nil }|nil
function Store.touchAsync(path, ref, opts)
    if not path or path == "" or type(ref) ~= "table" then
        return
    end
    if type(ref.book_key) ~= "string" or ref.book_key == "" then
        return
    end
    if type(ref.source_id) ~= "string" or ref.source_id == "" then
        return
    end
    local path_copy = path
    local ref_copy = {
        book_key = ref.book_key,
        source_id = ref.source_id,
        stable_id = ref.stable_id,
    }
    local opts_copy = opts and { chapter_idx = opts.chapter_idx } or nil
    DbQueue.run(function()
        local OpenDB = require("utils.db.open")
        local BookDB = require("utils.db.book")
        local filename = ref_copy.stable_id
        OpenDB.upsert(path_copy, {
            book_key = ref_copy.book_key,
            source_id = ref_copy.source_id,
            stable_id = filename,
            chapter_idx = opts_copy and opts_copy.chapter_idx,
            last_open = os.time(),
        })
    end)
end

--- 打开/下载后登记：写 opens；有 partialMD5 则更新 books.md5/filename（已废弃）
---@deprecated 使用 Store.touchAsync 代替
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
    OpenDB.upsert(path, {
        book_key = ref.book_key,
        source_id = ref.source_id,
        stable_id = filename,
        chapter_idx = opts.chapter_idx,
        last_open = os.time(),
    })
    local digest = partialMd5(path)
    if digest and filename then
        BookDB.setMd5ByKey(ref.book_key, digest, filename)
        return
    end
    if digest then
        BookDB.setMd5ByKey(ref.book_key, digest, nil)
        return
    end
    if not filename then
        return
    end
    local row = BookDB.get(ref.book_key)
    if row then
        if row.filename == filename then
            return
        end
        BookDB.upsert({
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
    BookDB.upsert({
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
    local v = OpenDB.get(path)
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
            local book = BookDB.get(v.book_key)
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
        local book = BookDB.get(v.book_key)
        source_id = book and book.source_id
    end
    if not source_id or source_id == "" then
        return nil
    end
    return {
        ref = BookRef.new(source_id, v.stable_id),
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
    Paths.ensureCacheRoot()
    DbBase.open()
    local now = os.time()
    BookDB.expireBefore(now - META_TTL)
    TocDB.deleteExpired(now - TOC_TTL)

    local map = OpenDB.all()
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
                                        OpenDB.delete(book_dir)
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
            OpenDB.delete(path)
        end
    end
    return removed
end

--- 过期缓存清理放到子进程（扫盘 + SQLite）。
---@param cb fun(ok: boolean, removed: number|nil)|nil
---@return { cancel: fun() }
function Store.cleanupStaleAsync(cb)
    cb = cb or function() end
    local ffiUtil = require("ffi/util")
    local task = Task.run(function(_, write_fd)
        ffiUtil.writeToFD(write_fd, tostring(Store.cleanupStale()), true)
    end, {
        pipe = true,
        on_done = function(raw)
            cb(true, tonumber(raw) or 0)
        end,
        on_failed = function()
            cb(false)
        end,
    })
    return {
        cancel = function()
            task:abort()
        end,
    }
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

--- lfs.dir 返回 (iter, dir_obj)；必须成对保存，调用 iter(dir_obj)。
---@param path string
---@return { path: string, iter: fun(state: any): string|nil, state: any }|nil
local function pushDir(path)
    local iter, state = lfs.dir(path)
    if type(iter) ~= "function" or state == nil then
        return nil
    end
    return { path = path, iter = iter, state = state }
end

--- Cooperative recursive directory removal. Work is bounded per UI turn.
---@param dir string
---@param done fun(ok: boolean, err: any)
---@return { cancel: fun() }
local function purgeDirAsync(dir, done)
    local cancelled = false
    local stack = {}
    if lfs.attributes(dir, "mode") == "directory" then
        local entry = pushDir(dir)
        if entry then
            stack[1] = entry
        end
    end

    local function finish(ok, err)
        if not cancelled then
            done(ok, err)
        end
    end
    local function step()
        if cancelled then
            return
        end
        local budget = 24
        while budget > 0 and #stack > 0 do
            budget = budget - 1
            local top = stack[#stack]
            local name = top.iter(top.state)
            if not name then
                local ok, err = os.remove(top.path)
                table.remove(stack)
                if not ok then
                    finish(false, err)
                    return
                end
            elseif name ~= "." and name ~= ".." then
                local path = top.path .. "/" .. name
                local mode = lfs.attributes(path, "mode")
                if mode == "directory" then
                    local entry = pushDir(path)
                    if entry then
                        stack[#stack + 1] = entry
                    end
                elseif mode then
                    local ok, err = os.remove(path)
                    if not ok then
                        finish(false, err)
                        return
                    end
                end
            end
        end
        if #stack == 0 then
            finish(true)
        else
            UIManager:nextTick(step)
        end
    end
    UIManager:nextTick(step)
    return {
        cancel = function()
            cancelled = true
        end,
    }
end

--- Cooperative cache size scan. Never walk the cache tree during widget build.
---@param cb fun(bytes: number)
---@return { cancel: fun() }
function Store.sizeBytesAsync(cb)
    local cancelled = false
    local total = 0
    local dir = Paths.cacheDir()
    local stack = {}
    if lfs.attributes(dir, "mode") == "directory" then
        local entry = pushDir(dir)
        if entry then
            stack[1] = entry
        end
    end
    local function finish()
        local db_file = Paths.dbPath()
        if lfs.attributes(db_file, "mode") == "file" then
            total = total + (tonumber(lfs.attributes(db_file, "size") or 0) or 0)
        end
        if not cancelled then
            cb(total)
        end
    end
    local function step()
        if cancelled then
            return
        end
        local budget = 48
        while budget > 0 and #stack > 0 do
            budget = budget - 1
            local top = stack[#stack]
            local name = top.iter(top.state)
            if not name then
                table.remove(stack)
            elseif name ~= "." and name ~= ".." then
                local path = top.path .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then
                    local entry = pushDir(path)
                    if entry then
                        stack[#stack + 1] = entry
                    end
                elseif attr and attr.mode == "file" then
                    total = total + (tonumber(attr.size) or 0)
                end
            end
        end
        if #stack == 0 then
            finish()
        else
            UIManager:nextTick(step)
        end
    end
    UIManager:nextTick(step)
    return {
        cancel = function()
            cancelled = true
        end,
    }
end

--- Cooperative cache size label.
---@param cb fun(label: string)
---@return { cancel: fun() }
function Store.sizeLabelAsync(cb)
    return Store.sizeBytesAsync(function(n)
        local util = require("util")
        cb(n > 0 and (util.getFriendlySize(n) or tostring(n)) or "0")
    end)
end

--- Clear file cache + tocs/opens without monopolising the UI thread.
---@param cb fun(ok: boolean, err: any)|nil
---@return { cancel: fun() }
function Store.clearAsync(cb)
    cb = cb or function() end
    local ok_img, Image = pcall(require, "ui.components.image")
    if ok_img and Image and Image.abortPending then
        Image.abortPending()
    end
    local dir = Paths.cacheDir()
    local cancelled = false
    local purge_job
    local db_job
    -- 先清 DB 再删文件：即使文件删除失败，DB 记录已干净，不会产生孤立引用
    db_job = Task.run(function()
        DbBase.open()
        TocDB.clear()
        OpenDB.clear()
        BookDB.stripMeta()
    end, {
        on_done = function()
            if cancelled then
                return
            end
            -- DB 清理成功后再删文件
            purge_job = purgeDirAsync(dir, function(ok, err)
                if cancelled then
                    return
                end
                if not ok then
                    -- 文件删除失败但 DB 已清：重建 cache 目录即可
                    Paths.ensureCacheRoot()
                    logger.warn("book cache file purge failed (db already cleared)", dir, err)
                    cb(false, err)
                    return
                end
                Paths.ensureCacheRoot()
                logger.info("book cache cleared", dir)
                cb(true)
            end)
        end,
        on_failed = function(db_err)
            if cancelled then
                return
            end
            logger.warn("book cache db clear failed, skipping file purge", db_err)
            cb(false, db_err)
        end,
    })
    return {
        cancel = function()
            cancelled = true
            if purge_job then
                purge_job:cancel()
            end
            if db_job then
                db_job:abort()
            end
        end,
    }
end

return Store
