--[[--
本地书籍/封面缓存 + filemap/metamap。
filemap：本地路径 -> { filename, last_open }
metamap：远端 filename -> 书籍元数据

@module koplugin.book.moon.cache
--]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Paths = require("moon.paths")
local StatsDb = require("stats_db")

local Cache = {}

local FILEMAP_KEY = "book_plugin_filemap_v2"
local METAMAP_KEY = "book_plugin_meta_v2"
local LOCAL_BOOK_TTL = 90 * 24 * 60 * 60

local function readMap(key)
    local map = G_reader_settings:readSetting(key)
    return type(map) == "table" and map or {}
end

local function writeMap(key, map)
    G_reader_settings:saveSetting(key, map)
end

local function basename(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return path:match("([^/\\]+)$") or path
end

local function bookFilenameOf(book)
    if type(book) ~= "table" then
        return nil
    end
    return basename(book.filename or book.fileName or book.file or book.path)
end

local function metaFromBook(book)
    local filename = bookFilenameOf(book)
    if not filename then
        return nil
    end
    return {
        filename = filename,
        bookName = book.bookName or book.title,
        author = book.author,
        favorite = book.favorite,
        category = book.category,
        series = book.series,
        description = book.description or book.intro or book.summary,
        progressPercent = book.progressPercent,
    }
end

function Cache.bookPath(filename)
    Paths.ensureLayout()
    return Paths.bookDir() .. "/" .. (basename(filename) or filename)
end

function Cache.touch(path, filename)
    if not path or path == "" or not filename or filename == "" then
        return
    end
    local map = readMap(FILEMAP_KEY)
    map[path] = {
        filename = filename,
        last_open = os.time(),
    }
    writeMap(FILEMAP_KEY, map)
    StatsDb.rememberPathFilename(path, filename)
end

function Cache.remoteFilename(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local v = readMap(FILEMAP_KEY)[path]
    if type(v) == "table" and type(v.filename) == "string" and v.filename ~= "" then
        return v.filename
    end
    return basename(path)
end

function Cache.remember(book)
    local meta = metaFromBook(book)
    if not meta then
        return
    end
    local map = readMap(METAMAP_KEY)
    map[meta.filename] = meta
    writeMap(METAMAP_KEY, map)
end

function Cache.rememberMany(books)
    if type(books) ~= "table" then
        return
    end
    local map = readMap(METAMAP_KEY)
    local dirty = false
    for _, book in ipairs(books) do
        local meta = metaFromBook(book)
        if meta then
            map[meta.filename] = meta
            dirty = true
        end
    end
    if dirty then
        writeMap(METAMAP_KEY, map)
    end
end

function Cache.getMeta(filename)
    filename = basename(filename)
    if not filename then
        return {}
    end
    local meta = readMap(METAMAP_KEY)[filename]
    if type(meta) == "table" then
        return meta
    end
    return { filename = filename }
end

function Cache.findMeta(filename)
    if type(filename) ~= "string" or filename == "" then
        return nil
    end
    local map = readMap(METAMAP_KEY)
    local meta = map[filename]
    if type(meta) ~= "table" then
        meta = map[basename(filename)]
    end
    if type(meta) == "table" and (meta.bookName or meta.title) then
        return meta
    end
    return nil
end

local function removeCover(filename)
    if not filename or filename == "" then
        return
    end
    local ok, Cover = pcall(require, "ui.components.cover")
    if not ok or not Cover then
        return
    end
    local cached = Cover.cachedPath(nil, filename)
    if cached then
        pcall(os.remove, cached)
    end
    local base = Cover.pathFor(nil, filename)
    for _, ext in ipairs({ ".jpg", ".jpeg", ".png", ".webp", ".gif", "", ".part" }) do
        pcall(os.remove, base .. ext)
    end
end

function Cache.cleanupStale()
    local dir = Paths.bookDir()
    if lfs.attributes(dir, "mode") ~= "directory" then
        return 0
    end
    local now = os.time()
    local map = readMap(FILEMAP_KEY)
    local removed = 0
    local dirty = false

    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            if lfs.attributes(path, "mode") == "file" then
                local v = map[path]
                local filename = type(v) == "table" and v.filename or name
                local last_open = type(v) == "table" and tonumber(v.last_open) or 0
                if last_open <= 0 then
                    local attr = lfs.attributes(path)
                    last_open = attr and (tonumber(attr.access) or tonumber(attr.modification)) or 0
                end
                if last_open > 0 and (now - last_open) >= LOCAL_BOOK_TTL then
                    local ok = pcall(os.remove, path)
                    if ok and lfs.attributes(path, "mode") ~= "file" then
                        removed = removed + 1
                        if map[path] ~= nil then
                            map[path] = nil
                            dirty = true
                        end
                        removeCover(filename)
                        logger.info("book cleaned stale local", path)
                    end
                end
            end
        end
    end

    for path, _ in pairs(map) do
        if lfs.attributes(path, "mode") ~= "file" then
            map[path] = nil
            dirty = true
        end
    end
    if dirty then
        writeMap(FILEMAP_KEY, map)
    end
    return removed
end

function Cache.clear()
    local books, covers = 0, 0
    local ok_cover, Cover = pcall(require, "ui.components.cover")
    if ok_cover and Cover and Cover.abortPending then
        Cover.abortPending()
    end

    local function wipeDir(dir)
        local n = 0
        if lfs.attributes(dir, "mode") ~= "directory" then
            return n
        end
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then
                local path = dir .. "/" .. name
                if lfs.attributes(path, "mode") == "file" then
                    local ok = pcall(os.remove, path)
                    if ok and lfs.attributes(path, "mode") ~= "file" then
                        n = n + 1
                    end
                end
            end
        end
        return n
    end

    Paths.ensureLayout()
    books = wipeDir(Paths.bookDir())
    covers = wipeDir(Paths.coverDir())
    writeMap(FILEMAP_KEY, {})
    writeMap(METAMAP_KEY, {})
    logger.info("book cache cleared", books, covers)
    return books, covers
end

return Cache
