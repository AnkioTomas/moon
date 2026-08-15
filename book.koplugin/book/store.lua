--[[--
本地书库门面（store）

  books/opens → utils.db.*（book.sqlite3）
  epub/html 落盘：.moon/cache/<source>/book/<slug>/
  （整本 book.*；按章 N.html）

  身份 = (source_id, stable_id)；md5 是本地源的内容摘要，用于识别改名/移动

@module koplugin.book.book.store
--]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local Paths = require("utils.paths")
local DbBase = require("utils.db.base")
local BookDB = require("utils.db.book")
local OpenDB = require("utils.db.open")
local DbQueue = require("utils.db.queue")
local Task = require("utils.task")

local Store = {}

local META_TTL = 7 * 24 * 60 * 60
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
---@param stable_id string
---@param source_id string
---@return string
function Store.bookFilePath(stable_id, source_id)
    Paths.ensureBookWork(stable_id, source_id)
    return Paths.bookWorkDir(stable_id, source_id) .. "/book." .. bookExtension(stable_id)
end

--- 单章 HTML 路径（在线按章阅读落盘）
---@param stable_id string
---@param idx number|string
---@param source_id string
---@return string
function Store.chapterPath(stable_id, idx, source_id)
    Paths.ensureBookWork(stable_id, source_id)
    idx = tonumber(idx) or 0
    return Paths.bookWorkDir(stable_id, source_id) .. "/" .. tostring(idx) .. ".html"
end

--- 异步写入 books 元数据（fire-and-forget，不堵 UI）
---@param ref BookRef
---@param meta table
function Store.putMetaAsync(ref, meta)
    if type(ref) ~= "table" or type(meta) ~= "table" then
        return
    end
    local source_id = ref.source_id
    local stable_id = ref.stable_id
    if type(source_id) ~= "string" or source_id == "" then
        return
    end
    if type(stable_id) ~= "string" or stable_id == "" then
        return
    end
    local payload = {
        source_id = source_id,
        stable_id = stable_id,
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
            logger.warn("book.cache putMetaAsync failed", source_id, stable_id)
        end
    end)
end

--- 读 books 元数据；过 TTL（7 天）或 fetched_at=0 返回 nil。
--- 必须在 Task 子进程内调用（通过 getMetaAsync 间接使用）。
---@param source_id string
---@param stable_id string
---@return table|nil
local function getMetaSync(source_id, stable_id)
    if type(source_id) ~= "string" or source_id == "" then
        return nil
    end
    if type(stable_id) ~= "string" or stable_id == "" then
        return nil
    end
    DbBase.open()
    local data = BookDB.get(source_id, stable_id)
    if not data then
        return nil
    end
    if isExpired(data.fetched_at, META_TTL) then
        return nil
    end
    return {
        ref = BookRef.new(data.source_id, data.stable_id),
        stable_id = data.stable_id,
        source_id = data.source_id,
        md5 = data.md5,
        title = data.title,
        authors = data.authors,
        percent = tonumber(data.percent) or 0,
        category = data.category,
        favorite = data.favorite,
        series = data.series,
        intro = data.intro,
        fetched_at = data.fetched_at,
    }
end

--- 异步读 books 元数据；回调 fun(meta: table|nil)
---@param ref BookRef
---@param cb fun(meta: table|nil)
---@return { cancel: fun() }
function Store.getMetaAsync(ref, cb)
    if type(ref) ~= "table" or type(ref.source_id) ~= "string" or type(ref.stable_id) ~= "string" then
        UIManager:nextTick(function()
            cb(nil)
        end)
        return { cancel = function() end }
    end

    local cancelled = false
    local job = { cancel = function() cancelled = true end }
    local source_id, stable_id = ref.source_id, ref.stable_id

    UIManager:nextTick(function()
        if cancelled then
            return
        end
        local meta = getMetaSync(source_id, stable_id)
        cb(meta)
    end)

    return job
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
    Store.putMetaAsync(ref, meta)
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
                source_id = ref.source_id,
                stable_id = ref.stable_id,
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
---@param ref BookRef
---@param cb fun(meta: table|nil)
---@return { cancel: fun() }
function Store.findMetaAsync(ref, cb)
    return Store.getMetaAsync(ref, function(meta)
        if meta and meta.title then
            cb(meta)
        else
            cb(nil)
        end
    end)
end

--- 异步打开/下载后登记（fire-and-forget）
--- ref 由 BookRef.new 构造，两字段必有；不再重复校验。
---@param path string 本地 epub/html 路径
---@param ref BookRef
---@param opts { chapter_idx: number|nil }|nil
function Store.touchAsync(path, ref, opts)
    if not path or path == "" or type(ref) ~= "table" then
        return
    end
    local path_copy = path
    local ref_copy = {
        source_id = ref.source_id,
        stable_id = ref.stable_id,
    }
    local opts_copy = opts and { chapter_idx = opts.chapter_idx } or nil
    DbQueue.run(function()
        local OpenDB = require("utils.db.open")
        OpenDB.upsert({
            source_id = ref_copy.source_id,
            stable_id = ref_copy.stable_id,
            path = path_copy,
            chapter_idx = opts_copy and opts_copy.chapter_idx,
            last_open = os.time(),
        })
    end)
end

--- 本地路径 → opens 条目
---@param path string
---@return table|nil
function Store.entryFor(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return OpenDB.getByPath(path)
end

--- 本地路径 → 远端 stable_id
---@param path string
---@return string|nil
function Store.remoteFilename(path)
    local v = Store.entryFor(path)
    if v and type(v.stable_id) == "string" and v.stable_id ~= "" then
        return v.stable_id
    end
    return basename(path)
end

--- 进度/面板用身份：完整 BookRef + chapter_idx
---@param path string
---@return { ref: BookRef, chapter_idx: number|nil }|nil
function Store.identityFor(path)
    local v = Store.entryFor(path)
    if not v or not v.stable_id or not v.source_id then
        return nil
    end
    return {
        ref = BookRef.new(v.source_id, v.stable_id),
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

--- 清理过期 meta，并删掉连续 90 天未打开的书目录；顺带清失效 opens
---@return number 删除的目录/文件数
function Store.cleanupStale()
    Paths.ensureCacheRoot()
    DbBase.open()
    local now = os.time()
    BookDB.expireBefore(now - META_TTL)

    local rows = OpenDB.all()
    local map = {}
    for _, row in ipairs(rows) do
        if type(row.path) == "string" then
            map[row.path] = row
        end
    end
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
                                        if v then
                                            OpenDB.delete(v.source_id, v.stable_id)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    for _, row in ipairs(rows) do
        local mode = type(row.path) == "string" and lfs.attributes(row.path, "mode") or nil
        if mode ~= "file" and mode ~= "directory" then
            OpenDB.delete(row.source_id, row.stable_id)
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

--- Clear file cache + opens without monopolising the UI thread.
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
