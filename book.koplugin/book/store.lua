--[[--
书籍身份与异步落库。

books/chapters → utils.db.*（book.sqlite3）
身份 = (source_id, stable_id)；md5 是本地源的内容摘要，供扫盘识别改名/移动。
缓存扫盘/清量在 book.cache。

身份解析只有一条规则：物理路径精确查库——
章节文件查 chapters 表，整本书查 books.path；都未中时
.moon 内的文件拒开（必须从 Book 桌面打开），.moon 外的文件登记为 local 书。
各源只有在物理文件落地后调用 touchAsync；需要打开文件时等待其完成回调，
确保路径与章节身份已经写入数据库。

@module koplugin.book.book.store
--]]

local Paths = require("utils.paths")
local DbBase = require("utils.db.base")
local BookDB = require("utils.db.book")
local ChapterDB = require("utils.db.chapter")
local TocDB = require("utils.db.toc")
local DbQueue = require("utils.db.queue")
local logger = require("logger")

local Store = {}

--- 路径末段文件名
---@param path string
---@return string
local function basename(path)
    return path:match("([^/\\]+)$") or path
end

--- 属主源解析：身份属于哪个源就用哪个源实例（current 匹配直接用，否则按 id 建实例）；
--- 不可用返回 nil——跳过源同步，也不许错用 current（串书根因）。
--- 只在打开时（ensureIdentity）调用：registry.create 有构造开销，identityFor 读路径不挂。
---@param source_id string
---@return BookSource|nil
local function owningSource(source_id)
    return require("source.registry").resolve(source_id)
end

--- 异步保存列表中的书籍元数据；没有身份列的临时条目跳过。
---@param books table
function Store.rememberMany(books)
    local payload = {}
    local fetched_at = os.time()
    for _, book in ipairs(books) do
        if book.source_id and book.stable_id then
            payload[#payload + 1] = {
                source_id = book.source_id,
                stable_id = book.stable_id,
                md5 = book.md5,
                title = book.title,
                authors = book.authors,
                percent = tonumber(book.percent) or 0,
                category = book.category,
                favorite = book.favorite,
                series = book.series,
                intro = book.intro,
                fetched_at = fetched_at,
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

--- 异步打开/下载后登记。
--- 整本写 books.path；章节在同一事务写最新元数据、toc、books.path 和 chapters。
---@param path string 本地 epub/html 路径
---@param identity BookIdentity
---@param opts { chapter_idx: number|nil, toc: BookChapter[]|nil, book: Book|nil }|nil
---@param cb fun(ok: boolean|nil, err: any|nil)|nil
function Store.touchAsync(path, identity, opts, cb)
    local source_id, stable_id = identity.source_id, identity.stable_id
    local chapter_idx = opts and opts.chapter_idx
    local toc_payload
    if opts and opts.toc then
        local ok, payload = pcall(function() return require("json").encode(opts.toc) end)
        if not ok or type(payload) ~= "string" or payload == "" then
            if cb then cb(nil, payload or "failed to encode chapter toc") end
            return
        end
        toc_payload = payload
    end
    DbQueue.run(function()
        if not chapter_idx then
            assert(BookDB.touchPath(source_id, stable_id, path), "failed to register book path")
            return
        end

        assert(DbBase.ensure(), "failed to open book database")
        assert(DbBase.exec("BEGIN IMMEDIATE;"), "failed to begin path registration")
        local ok, err = pcall(function()
            local book = opts and opts.book
            if book then
                local row = {}
                for k, v in pairs(book) do row[k] = v end
                row.source_id = source_id
                row.stable_id = stable_id
                assert(BookDB.upsert(row), "failed to save book metadata")
            end
            if toc_payload then
                assert(TocDB.upsert(source_id, stable_id, toc_payload), "failed to save chapter toc")
            end
            assert(BookDB.touchPath(source_id, stable_id, path, chapter_idx), "failed to register book path")
            assert(ChapterDB.upsert({
                path = path,
                source_id = source_id,
                stable_id = stable_id,
                chapter_idx = chapter_idx,
            }), "failed to register chapter path")
        end)
        if ok then
            if not DbBase.exec("COMMIT;") then
                DbBase.exec("ROLLBACK;")
                error("failed to commit path registration")
            end
        else
            DbBase.exec("ROLLBACK;")
            error(err, 0)
        end
    end, {
        on_done = cb and function() cb(true) end or nil,
        on_failed = function(err)
            if cb then
                cb(nil, err)
            else
                logger.warn("book.store path registration failed", path, err)
            end
        end,
    })
end

--- 从数据库读取书籍目录；目录缺失或损坏返回 nil。
---@param identity BookIdentity
---@return BookChapter[]|nil
function Store.toc(identity)
    if not identity or not identity.source_id or not identity.stable_id then return nil end
    local payload = TocDB.get(identity.source_id, identity.stable_id)
    if not payload then return nil end
    local ok, toc = pcall(function() return require("json").decode(payload) end)
    if not ok or type(toc) ~= "table" or #toc == 0 then return nil end
    return toc
end

--- 进度/面板用身份：BookIdentity（含 source_id/stable_id）。
--- 唯一规则 = 路径精确查库：chapters（章节文件）→ books.path（整本书）。
---@param path string
---@return BookIdentity|nil
function Store.identityFor(path)
    local ch = ChapterDB.get(path)
    if ch then
        return {
            source_id = ch.source_id,
            stable_id = ch.stable_id,
            chapter_idx = ch.chapter_idx,
            book = BookDB.get(ch.source_id, ch.stable_id),
        }
    end
    local book = BookDB.getByPath(path)
    if book then
        return {
            source_id = book.source_id,
            stable_id = book.stable_id,
            chapter_idx = nil,
            book = book,
        }
    end
    return nil
end

--- 判断异步操作发起后，ReaderUI 是否仍打开同一物理文档。
---@param ui table|nil ReaderUI 实例
---@param identity BookIdentity|nil 发起操作时的文档身份
---@return boolean
function Store.isCurrentDocument(ui, identity)
    if not ui or not ui.document or not ui.document.file or not identity then
        return false
    end
    local current = Store.identityFor(ui.document.file)
    return current ~= nil
        and current.source_id == identity.source_id
        and current.stable_id == identity.stable_id
        and current.chapter_idx == identity.chapter_idx
end

--- 打开时确保身份：能解析则补登记打开记录；
--- .moon 内未知文件返回 nil（必须从 Book 桌面打开）；
--- .moon 外未入库文件一律当本地书登记（统计/进度挂到 local 源）。
--- 返回的身份附带属主源实例（source 字段，可能为 nil）。
--- DB 写入走队列异步落，返回的是内存身份（含 book/chapter 元数据），同 tick 再查 identityFor 不一定中。
---@param path string
---@return BookIdentity|nil
function Store.ensureIdentity(path)
    local id = Store.identityFor(path)
    if id then
        id.source = owningSource(id.source_id)
        Store.touchAsync(path, id, { chapter_idx = id.chapter_idx })
        return id
    end
    if Paths.isMoonPath(path) then
        return nil -- .moon 内未知文件必须从 Book 桌面打开
    end
    -- 未入库 → 当本地书登记（标题取文件名；md5 供扫盘改名识别）。
    -- 已有行（如扫盘已解析元数据、仅 path 被清掉）只补 path，不覆盖元数据。
    local ok, digest = pcall(function()
        return require("ffi/util").partialMD5(path)
    end)
    local name = basename(path)
    local title = name:gsub("%.[^%.]+$", "")
    local row = {
        source_id = "local",
        stable_id = path,
        md5 = ok and digest or nil,
        title = title,
        fetched_at = os.time(),
        path = path,
    }
    DbQueue.run(function()
        if not BookDB.get("local", path) then
            BookDB.upsert(row)
        end
        BookDB.touchPath("local", path, path, nil)
    end)
    return {
        source_id = "local",
        stable_id = path,
        chapter_idx = nil,
        book = row,
        source = owningSource("local"),
    }
end

return Store
