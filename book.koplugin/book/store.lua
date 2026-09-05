--[[--
书籍身份与数据库持久化。

books/chapters → db.*（book.sqlite3）
身份 = (source_id, stable_id)；md5 是本地源的内容摘要，供扫盘识别改名/移动。
缓存扫盘/清量在 book.cache。

身份解析只有一条规则：物理路径精确查库——
章节文件查 chapters 表，整本书查 books.path；都未中时
.moon 内的文件拒开（必须从月读桌面打开），.moon 外的文件登记为 local 书。
各源只有在物理文件落地后调用 Store.touch（同步写库），成功后才打开文件。

@module koplugin.book.book.store
--]]

local Paths = require("utils.paths")
local DbBase = require("db.base")
local BookDB = require("db.book")
local ChapterDB = require("db.chapter")

local Store = {}

--- 路径末段文件名
---@param path string
---@return string
local function basename(path)
    return path:match("([^/\\]+)$") or path
end

--- 保存列表中的书籍元数据；没有身份列的临时条目跳过。
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
                series = book.series,
                intro = book.intro,
                cover = book.cover,
                fetched_at = fetched_at,
                in_library = book.in_library,
            }
        end
    end
    if #payload == 0 then
        return
    end
    for i = 1, #payload do
        BookDB.upsertRemote(payload[i])
    end
end

--- 用完整书架快照对账 books 表：upsert 全部远端条目，未刷新的成员标 inactive（不删行）。
---@param source_id string
---@param books Book[]
---@return SyncResult|nil result
---@return string|nil err
function Store.reconcile(source_id, books)
    local incoming = {}
    for _, book in ipairs(books) do
        if book.stable_id ~= nil then incoming[tostring(book.stable_id)] = true end
    end
    local hidden = 0
    for _, stable_id in ipairs(BookDB.libraryStableIdsBySource(source_id)) do
        if not incoming[stable_id] then hidden = hidden + 1 end
    end
    if not BookDB.reconcile(source_id, books) then
        return nil, "failed to reconcile books"
    end
    return { pulled = #books, pushed = 0, hidden = hidden, conflicts = 0, skipped = false }
end

--- 章节登记事务体：最新元数据、books.path、toc、chapters 四步任一失败即返回错误。
---@param path string
---@param source_id string
---@param stable_id string
---@param opts { chapter_idx: number, toc_payload: string|nil, book: Book|nil }
---@return string|nil err
local function registerChapter(path, source_id, stable_id, opts)
    if opts.book then
        local row = {}
        for k, v in pairs(opts.book) do row[k] = v end
        row.source_id = source_id
        row.stable_id = stable_id
        if not BookDB.upsertRemote(row) then return "failed to save book metadata" end
    end
    if not BookDB.touchPath(source_id, stable_id, path) then return "failed to register book path" end
    if opts.toc_payload and not BookDB.setToc(source_id, stable_id, opts.toc_payload) then
        return "failed to save chapter toc"
    end
    if not ChapterDB.upsert({
        path = path,
        source_id = source_id,
        stable_id = stable_id,
        chapter_idx = opts.chapter_idx,
    }) then
        return "failed to register chapter path"
    end
    return nil
end

--- 打开/下载后登记物理路径。
--- 整本写 books.path；章节在同一事务写最新元数据、toc、books.path 和 chapters。
---@param path string 本地 epub/html 路径
---@param identity BookIdentity
---@param opts { chapter_idx: number|nil, toc: BookChapter[]|nil, book: Book|nil }|nil
---@return boolean ok
---@return string|nil err
function Store.touch(path, identity, opts)
    local source_id, stable_id = identity.source_id, identity.stable_id
    local chapter_idx = opts and opts.chapter_idx
    if not chapter_idx then
        if not BookDB.touchPath(source_id, stable_id, path) then
            return false, "failed to register book path"
        end
        return true
    end

    local toc_payload
    if opts.toc then
        local ok, payload = pcall(require("json").encode, opts.toc)
        if not ok or type(payload) ~= "string" or payload == "" then
            return false, payload or "failed to encode chapter toc"
        end
        toc_payload = payload
    end
    if not DbBase.ensure() then return false, "failed to open book database" end
    if not DbBase.exec("BEGIN IMMEDIATE;") then return false, "failed to begin path registration" end
    local err = registerChapter(path, source_id, stable_id, {
        chapter_idx = chapter_idx,
        toc_payload = toc_payload,
        book = opts.book,
    })
    if not err and not DbBase.exec("COMMIT;") then
        err = "failed to commit path registration"
    end
    if err then
        DbBase.exec("ROLLBACK;")
        return false, err
    end
    return true
end

--- 从数据库读取书籍目录；目录缺失或损坏返回 nil。
---@param identity BookIdentity
---@return BookChapter[]|nil
function Store.toc(identity)
    if not identity or not identity.source_id or not identity.stable_id then return nil end
    local payload = BookDB.getToc(identity.source_id, identity.stable_id)
    if not payload then return nil end
    local ok, toc = pcall(require("json").decode, payload)
    if not ok or type(toc) ~= "table" or #toc == 0 then return nil end
    return toc
end

--- 本地目录与已缓存章节数是否完全一致；目录未知时不能宣称缓存完成。
---@param identity BookIdentity|nil
---@return boolean
function Store.allChaptersCached(identity)
    local toc = Store.toc(identity)
    if not toc or #toc == 0 then return false end
    return ChapterDB.countByBook(identity.source_id, identity.stable_id) == #toc
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
--- .moon 内未知文件返回 nil（必须从月读桌面打开）；
--- .moon 外未入库文件一律当本地书登记（统计/进度挂到 local 源）。
--- 返回的身份附带属主源实例（source 字段，可能为 nil）：身份属于哪个源就用哪个源实例
--- （registry.resolve：current 匹配直接用，否则按 id 建实例），不许错用 current（串书根因）。
---@param path string
---@return BookIdentity|nil
function Store.ensureIdentity(path)
    local registry = require("source.registry")
    local id = Store.identityFor(path)
    if id then
        id.source = registry.resolve(id.source_id)
        -- 路径已在库里（chapters/books.path 命中），只需刷新打开时间
        BookDB.touchPath(id.source_id, id.stable_id, path)
        return id
    end
    if Paths.isMoonPath(path) then
        return nil -- .moon 内未知文件必须从月读桌面打开
    end
    -- 未入库 → 当本地书登记（标题取文件名；md5 供扫盘改名识别）。
    -- 已有行（如扫盘已解析元数据、仅 path 被清掉）只补 path，不覆盖元数据。
    local row = {
        source_id = "local",
        stable_id = path,
        md5 = require("util").partialMD5(path),
        title = basename(path):gsub("%.[^%.]+$", ""),
        fetched_at = os.time(),
        path = path,
    }
    if not BookDB.get("local", path) then
        BookDB.upsert(row)
    end
    BookDB.touchPath("local", path, path)
    return {
        source_id = "local",
        stable_id = path,
        chapter_idx = nil,
        book = row,
        source = registry.resolve("local"),
    }
end

return Store
