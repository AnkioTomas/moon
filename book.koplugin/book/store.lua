--[[--
本地书库门面（store）

  books/opens → utils.db.*（book.sqlite3）
  epub/html 落盘：.moon/cache/<source>/book/<slug>/
  （整本 book.*；按章 N.html）

  身份 = (source_id, stable_id)；md5 是本地源的内容摘要，用于识别改名/移动
  缓存扫盘/清量在 book.cache。

@module koplugin.book.book.store
--]]

local logger = require("logger")
local UIManager = require("ui/uimanager")
local Paths = require("utils.paths")
local DbBase = require("utils.db.base")
local BookDB = require("utils.db.book")
local OpenDB = require("utils.db.open")
local DbQueue = require("utils.db.queue")

local Store = {}

local META_TTL = 7 * 24 * 60 * 60
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
        local ok = BookDB.upsert(payload)
        if not ok then
            logger.warn("book.cache putMetaAsync failed", source_id, stable_id)
        end
    end)
end

--- 同步读 books 元数据；过 TTL（7 天）或 fetched_at=0 返回 nil。
--- 经 getMetaAsync 在 nextTick 中调用（主线程，单连接由 DbQueue/调用方保证）。
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

return Store
