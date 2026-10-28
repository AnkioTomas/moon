--[[--
书籍身份与数据库持久化。

books/chapters → db.*（book.sqlite3）
身份 = (source_id, stable_id)；md5 是本地源的内容摘要，供扫盘识别改名/移动。
缓存扫盘/清量在 book.cache。

身份解析只有一条规则：物理路径精确查库——
章节文件查 chapters 表，整本书查 books.path；都未中时
.moon 内的文件拒开（必须从月读桌面打开），.moon 外的文件登记为 local 书。
各源只有在物理文件落地后调用 Store.touch（同步写库），成功后才打开文件。

touch 新建行 deleted=1（只登记身份 / 路径，不上架）；touch 失败就停止打开链路。
清缓存保留工作目录里的 KOReader .sdr 边车（阅读位置、书签、标注）；删书（markDeleted）连边车一起清。

@module koplugin.book.book.store
--]]

local Paths = require("utils.paths")
local DB = require("utils.db")
local BookDB = require("book.books_db")
local ChapterDB = require("book.chapters_db")
local logger = require("utils.log")

local Store = {}

--- 保存列表中的书籍元数据；没有身份列的临时条目跳过。
---@param books table
function Store.rememberMany(books)
    local payload = {}
    for _idx, book in ipairs(books) do
        if book.source_id and book.stable_id then
            local row = {
                source_id = book.source_id,
                stable_id = book.stable_id,
                md5 = book.md5,
                title = book.title,
                authors = book.authors,
                category = book.category,
                series = book.series,
                intro = book.intro,
                cover = book.cover,
                deleted = book.deleted,
                meta = book.meta,
            }
            payload[#payload + 1] = row
        end
    end
    if #payload == 0 then
        return
    end
    BookDB.upsertRemoteMany(payload)
end

---@param path string|nil
---@return boolean
local function inCache(path)
    local root = Paths.cacheDir() .. "/"
    return type(path) == "string" and path:sub(1, #root) == root
end

local trash_seq = 0

--- 工作目录里的 KOReader 边车目录名（`book.sdr` / `1.sdr`…）：清缓存保留，删书一起清。
---@param dir string
---@param lfs table
---@return string[]
local function sidecarDirs(dir, lfs)
    local out = {}
    if type(lfs.dir) ~= "function" then return out end
    local iter, state = lfs.dir(dir)
    if type(iter) ~= "function" then return out end
    for name in iter, state do
        if name ~= "." and name ~= ".." and name:match("%.sdr$") then
            out[#out + 1] = name
        end
    end
    return out
end

--- 删单书工作目录（整本/章节/图片）与封面文件，并撤掉目录下的章节登记。
--- keep_sidecar 为真（清缓存）时先把 `.sdr` 边车搬回重建成的工作目录：正文重下路径不变，
--- 阅读位置、书签、标注原样可用，符合「清理缓存只删可重新生成的缓存」。
---@param source_id string
---@param stable_id string
---@param keep_sidecar boolean|nil
---@param keep_cover boolean|nil 保留封面文件
---@return boolean ok 章节登记是否撤掉
---@return string|nil leftover purge 失败时为 "partial"
local function purgeBookFiles(source_id, stable_id, keep_sidecar, keep_cover)
    local dir = Paths.bookWorkDir(stable_id, source_id)
    local leftover
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") == "directory" then
        local keep = keep_sidecar and sidecarDirs(dir, lfs) or nil
        -- 漫画工作目录动辄上千张图，同步删要卡好几秒：同盘改名移走即刻生效，再分 tick 慢慢删。
        -- 改名失败才退回同步删；中途关机留下的 .trash 由「清空缓存」一并清掉。
        trash_seq = trash_seq + 1
        local trash = Paths.cacheDir() .. "/.trash"
        local moved = trash .. "/" .. os.time() .. "-" .. trash_seq
        lfs.mkdir(trash)
        if os.rename(dir, moved) then
            if keep and #keep > 0 and lfs.mkdir(dir) then
                for _idx, name in ipairs(keep) do
                    os.rename(moved .. "/" .. name, dir .. "/" .. name)
                end
            end
            require("book.cache").purgeAsync(moved)
        elseif not require("ffi/util").purgeDir(dir) then
            logger.warn("book cache purge failed", dir)
            leftover = "partial"
        end
    end
    if not keep_cover then os.remove(Paths.coverPath(stable_id, source_id)) end
    return ChapterDB.deleteUnder(dir), leftover
end

--- 本地删除：标 deleted 待同步，并清章节缓存/封面。书架列表立刻看不到。
---@param source_id string
---@param stable_id string
---@return boolean ok
---@return string|nil leftover purge 失败时为 "partial"
function Store.markDeleted(source_id, stable_id)
    if not BookDB.markDeleted(source_id, stable_id) then
        return false
    end
    local _unregistered, leftover = purgeBookFiles(source_id, stable_id)
    return true, leftover
end

--- 清单书本地缓存：工作目录、封面、封面网络图，以及 .moon/cache 内的 books.path。
--- 元数据、目录、进度、统计保留；.moon/cache 外的原书（本地源）不动。
--- keep_cover 为真（软删除）只删文档，封面文件与封面网络图也留着。
---@param source_id string
---@param stable_id string
---@param keep_cover boolean|nil
---@return boolean ok 路径登记是否清干净
---@return string|nil leftover purge 失败时为 "partial"
function Store.clearCache(source_id, stable_id, keep_cover)
    local ok, leftover = purgeBookFiles(source_id, stable_id, true, keep_cover)
    local row = BookDB.get(source_id, stable_id)
    if not row then return ok, leftover end
    local cached_cover = not keep_cover and require("ui.themes.widgets.image.download").cached(row.cover)
    if cached_cover then os.remove(cached_cover) end
    if inCache(row.path) then
        os.remove(row.path)
        ok = BookDB.touchPath(source_id, stable_id, nil) and ok
    end
    return ok, leftover
end

--- 软删除：清本地文档（保留封面），书留库里标 hidden，书架默认不显示；
--- 元数据、进度、标注都在，可在书架筛选「软删除」里恢复。纯本地操作，不碰远端与同步状态。
---@param source_id string
---@param stable_id string
---@return boolean
function Store.softDelete(source_id, stable_id)
    if not Store.clearCache(source_id, stable_id, true) then
        return false
    end
    return BookDB.setHidden(source_id, stable_id, true)
end

--- 章节登记事务体：最新元数据、books.path、chapters 任一失败即返回错误。
---@param path string
---@param source_id string
---@param stable_id string
---@param opts { chapter_idx: number, book: Book|nil }
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
--- 整本写 books.path；章节在同一事务写最新元数据、books.path 和 chapters。
--- 目录不经这里：源的 loadTocAsync 拿到目录即经 source.toc 落库。
---@param path string 本地 epub/html 路径
---@param identity BookIdentity
---@param opts { chapter_idx: number|nil, book: Book|nil }|nil
---@return boolean ok
---@return string|nil err
function Store.touch(path, identity, opts)
    local source_id, stable_id = identity.source_id, identity.stable_id
    if not (opts and opts.chapter_idx) then
        if not BookDB.touchPath(source_id, stable_id, path) then
            return false, "failed to register book path"
        end
        return true
    end
    if not DB.ensure() then return false, "failed to open book database" end
    local err
    local ok = DB.transaction(function()
        err = registerChapter(path, source_id, stable_id, {
            chapter_idx = opts.chapter_idx,
            book = opts.book,
        })
        return err == nil
    end)
    if not ok then return false, err or "failed to commit path registration" end
    return true
end

--- 在线书是否已离线到 .moon/cache（可清理）：章节源只要缓存过任意一章（不要求从当前章起连续，
--- 否则读到没缓存的章就没有清理入口），整本源看 path 落在 cache 内。
--- 本地源原书在 cache 外，恒为 false。
---@param book Book
---@return boolean
function Store.isCached(book)
    local meta = require("source.registry").meta(book.source_id)
    if meta and meta.type == "chapter" then
        return require("book.chapters_db").has(book.source_id, book.stable_id)
    end
    return inCache(book.path)
end

--- 后台校验下载登记：文件被手动删掉的书撤 books.path，章节撤 chapters 行，已下载标记随之消失。
--- 主进程取路径 → 子进程只 stat → 回主进程复核后写库（子进程禁止碰 sqlite）。
--- 没有登记路径时不起任务、返回 nil，cb 不会被调用。
---@param scope string|string[] 书库范围（Catalog.libraryScope）
---@param cb fun(changed: integer) 撤掉的登记条数
---@return table|nil job 可 :cancel()
function Store.verifyDownloadsAsync(scope, cb)
    local books = BookDB.pathsBySource(scope)
    local paths = {}
    for i, row in ipairs(books) do paths[i] = row.path end
    for _idx, path in ipairs(ChapterDB.pathsBySource(scope)) do paths[#paths + 1] = path end
    if #paths == 0 then return nil end
    local lfs = require("libs/libkoreader-lfs")
    return require("workers.job").run(function()
        local missing = {}
        for i, path in ipairs(paths) do
            if not lfs.attributes(path, "mode") then missing[#missing + 1] = i end
        end
        return missing
    end, {
        name = "store.verify_downloads",
        kind = "light",
        on_done = function(missing)
            local gone_books, gone_chapters = {}, {}
            for _idx, i in ipairs(missing or {}) do
                -- 子进程结果可能已过时（期间重新下载），写库前复核
                local path = paths[i]
                if not lfs.attributes(path, "mode") then
                    if books[i] then gone_books[#gone_books + 1] = books[i]
                    else gone_chapters[#gone_chapters + 1] = path end
                end
            end
            local changed = 0
            if #gone_books > 0 and BookDB.clearPaths(gone_books) then changed = changed + #gone_books end
            if #gone_chapters > 0 and ChapterDB.deleteMany(gone_chapters) then
                changed = changed + #gone_chapters
            end
            logger.dbg("book download verify", #paths, "checked", #gone_books, "books",
                #gone_chapters, "chapters", changed, "cleared")
            cb(changed)
        end,
        on_failed = function(err)
            logger.warn("book download verify failed", err)
            cb(0)
        end,
    })
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
    -- 衍生版（排版 / 双语）不登记路径，身份跟原书走
    local origin = require("reader.session.derived_note").originOf(path)
    local id = origin and Store.identityFor(origin)
    if id then id.derived = true end
    return id
end

--- 打开时确保身份：能解析则把 books.path 指向这次打开的文件；
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
        id.ephemeral = id.source and id.source.ephemeral or false
        -- 路径已在库里；章节文件可能绕过桌面（KOReader 历史）打开，books.path 跟到这一章
        if not id.derived and not BookDB.touchPath(id.source_id, id.stable_id, path) then
            logger.warn("book identity touch failed", id.source_id, id.stable_id, path)
        end
        return id
    end
    if Paths.isMoonPath(path) then
        return nil -- .moon 内未知文件必须从月读桌面打开
    end
    -- 未入库 → 只 touch 身份行（deleted=1，不上架），挂进度/统计用。
    -- 禁止 upsert 上架：否则库外打开的文件会被当成书架成员，EndOfBook 误接管。
    if not BookDB.touchPath("local", path, path) then
        logger.warn("book identity touch failed", "local", path, path)
    end
    local book = BookDB.get("local", path) or {
        source_id = "local",
        stable_id = path,
        title = require("utils.text").basename(path):gsub("%.[^%.]+$", ""),
        deleted = 1,
        path = path,
    }
    if book.title == nil or book.title == "" then
        book.title = require("utils.text").basename(path):gsub("%.[^%.]+$", "")
    end
    if book.md5 == nil then
        book.md5 = require("util").partialMD5(path) --[[@as string|nil]]
    end
    return {
        source_id = "local",
        stable_id = path,
        chapter_idx = nil,
        book = book,
        source = registry.resolve("local"),
    }
end

return Store
