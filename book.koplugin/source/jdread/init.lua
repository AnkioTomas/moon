--[[--
京东读书数据源门面。

cookie + 设备 uuid，签名与章节 AES 在 protocol.lua。书架用 source.shelf；进度双向，无笔记、无统计。
目录只认下载协议版本 5（EPUB 按文件成章）和 3（网文），其余版本作废重拉。没有 ebook_id 的详情不进缓存。
段评借用微信读书同一本书（chapter_links），只在本章自己没有段评时借。

@module koplugin.book.source.jdread
--]]

local Client = require("source.jdread.client")
local Mapper = require("source.jdread.mapper")
local Toc = require("source.toc")
local Assets = require("source.assets")
local Paths = require("utils.paths")
local Request = require("http.request")
local SourceBase = require("source.base")
local Shelf = require("source.shelf")
local Browse = require("source.browse")
local Progress = require("book.progress")
local logger = require("utils.log")
local _ = require("gettext")

local Jdread = {}

---@return BookSourceMeta
function Jdread.meta()
    return SourceBase.loadMeta("jdread")
end

---@class JdreadSource : SourceBase
---@field _client JdreadClient
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return JdreadSource
function Jdread.new()
    local cfg = require("utils.settings").getSource("jdread")
    local meta = Jdread.meta()
    return setmetatable({
        id = meta.id,
        name = meta.name,
        type = meta.type,
        _client = Client:new{ cookie = cfg.cookie, uuid = cfg.uuid },
    }, Source)
end

---@return SourceCapabilities
function Source:capabilities()
    return {
        scrape = false,
        edit = false,
        stats_pull = false,
    }
end

---@return boolean
function Source:configured()
    return self._client:configured()
end

---@param opts { dirty_only?: boolean, force?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: string|nil)
---@return { cancel: fun() }
function Source:syncBooksAsync(opts, cb)
    return Shelf.syncAsync(self.id, self._client, Mapper.shelfList, opts, cb)
end

--- 书城搜索：只取第一页。
---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Source:searchAsync(keyword, cb)
    return self._client:searchAsync(keyword, 1, 20, function(wire, err)
        if not wire then cb(nil, err); return end
        cb({ data = Mapper.search(wire) })
    end)
end

local RANK_PAGE = 20

--- 书城浏览：榜单类别（出版 / 男生 / 女生）、榜单、周期、分类四行 chip，节点是「类别:榜单:周期:分类」，
--- 缺省出版首个榜单的周榜。菜单与分类树每次现取，新鲜度由数据获取层缓存（source.store_cache）管；分类 id 只认对应类别根下一级。
---@param opts { node?: string, limit?: integer }
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Source:browseAsync(opts, cb)
    local handle = {}
    function handle.cancel()
        if handle.inner then handle.inner.cancel() end
    end
    -- 回调同步完成时已在 show 里换上在途句柄，外层赋值不能再覆盖（同 client 书架分批的 mine 记法）。
    local step = 0
    local function show(menu)
        step = step + 1
        local tid, kid, period, cat = (opts.node or ""):match("^(%d+):(%d+):(%a+):(%d*)$")
        local function pick(rows, key, want)
            for _idx, row in ipairs(rows) do
                if tostring(row[key]) == want then return row end
            end
            return rows[1]
        end
        local rtype = pick(menu.types, "type", tid)
        local kind = pick(rtype.kinds, "kind", kid)
        local per = pick(kind.periods, "period", period)
        cat = cat or ""
        local function id(t, k, p, c)
            return t.type .. ":" .. k.kind .. ":" .. p.period .. ":" .. c
        end
        local node = id(rtype, kind, per, cat)
        local types, kinds, periods = {}, {}, {}
        for _idx, t in ipairs(menu.types) do
            types[#types + 1] = { id = id(t, t.kinds[1], t.kinds[1].periods[1], ""), title = t.name }
        end
        for _idx, k in ipairs(rtype.kinds) do
            kinds[#kinds + 1] = { id = id(rtype, k, pick(k.periods, "period", per.period), cat), title = k.name }
        end
        for _idx, p in ipairs(kind.periods) do
            periods[#periods + 1] = { id = id(rtype, kind, p, cat), title = p.name }
        end
        local cats = { { id = id(rtype, kind, per, ""), title = _("全部") } }
        for _idx, sub in ipairs(menu.categories[rtype.name] or {}) do
            cats[#cats + 1] = { id = id(rtype, kind, per, tostring(sub.id)), title = sub.name }
        end
        local groups = {
            Browse.group(types, id(rtype, rtype.kinds[1], rtype.kinds[1].periods[1], "")),
            Browse.group(kinds, node),
            Browse.group(cats, node),
        }
        if #periods > 1 then table.insert(groups, 3, Browse.group(periods, node)) end
        handle.inner = Browse.pages(function(page, done)
            return self._client:rankAsync(kind.kind, per.period, cat, page, RANK_PAGE, function(wire, err)
                if not wire then
                    done(nil, err)
                    return
                end
                local rows = type(wire.data) == "table" and wire.data or {}
                done(Mapper.shelfList(rows), nil, #rows >= RANK_PAGE)
            end)
        end, opts.limit or 40, groups, cb)
    end
    local first = self._client:rankTypesAsync(function(types, err)
        if not types then cb(nil, err); return end
        local mine = step
        local second = self._client:categoriesAsync(function(tree, err2)
            if not tree then cb(nil, err2); return end
            local categories = {}
            for _idx, root in ipairs(tree.data.category_list) do
                categories[root.show_name] = root.sub_category
            end
            show({ types = types.data, categories = categories })
        end)
        if step == mine then handle.inner = second end
    end)
    if step == 0 then handle.inner = first end
    return handle
end

---@param identity BookIdentity
---@param cb fun(book: Book|nil, err: string|nil)
---@return CancelHandle|nil
function Source:getDetailAsync(identity, cb)
    return self._client:bookInfoAsync(identity.stable_id, function(wire, err)
        if not wire then cb(nil, err); return end
        -- 没有 ebook_id 时 Mapper.book 会得到 stable_id "nil"，不能写进缓存。
        if type(wire.data) ~= "table" or wire.data.ebook_id == nil then cb(nil, _("书籍详情为空")); return end
        local book = Mapper.book(wire.data)
        local existing = require("book.books_db").get(self.id, book.stable_id)
        if existing then
            book.deleted = existing.deleted
        end
        local progress = require("book.progress_db").get(self.id, book.stable_id)
        if progress then
            book.percent = Progress.clampPercent(progress.fraction, false, true)
        end
        require("book.store").rememberMany({ book })
        cb(book)
    end)
end

--- 目录版本 → download/chapter 查询参数（见 Mapper.chapters）。
--- 版本 5 是按文件成章、锚点小节挂 anchors 的 EPUB 目录；版本 2（一条目录一章）会把同一文件
--- 下载多遍，版本 4 丢了小节，均已失效。
local DOWNLOAD_QUERY = {
    [3] = function(uid) return { type = 1, ids = uid } end,
    [5] = function(uid) return { indexes = uid } end,
}

--- 只认下载协议目录；旧 cread 目录（版本 1）、旧 EPUB 目录（版本 2/4）与无版本目录一律失效。
---@param toc BookChapter[]|nil
---@return boolean
function Source:isTocCurrent(toc)
    return type(toc) == "table" and type(toc[1]) == "table"
        and DOWNLOAD_QUERY[toc[1].toc_version] ~= nil
end

--- 读有效目录缓存；失效格式当场清掉库里那份，交给调用方重新拉取。
---@param self JdreadSource
---@param identity BookIdentity
---@return BookChapter[]|nil
local function currentToc(self, identity)
    local toc = Toc.read(identity.source_id, identity.stable_id)
    if toc == nil or self:isTocCurrent(toc) then return toc end
    Toc.drop(identity.source_id, identity.stable_id)
    return nil
end

--- 强制拉取目录并写回缓存。
---@param self JdreadSource
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }
local function fetchTocAsync(self, identity, cb)
    return self._client:catalogAsync(identity.stable_id, function(wire, err)
        if not wire then cb(nil, err); return end
        local chapters = Mapper.chapters(wire)
        if not chapters then cb(nil, _("章节列表为空")); return end
        if not Toc.put(identity.source_id, identity.stable_id, chapters) then
            cb(nil, _("章节目录保存失败"))
            return
        end
        cb(chapters)
    end)
end

---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:loadTocAsync(identity, cb)
    local cached = currentToc(self, identity)
    if cached then
        local cancelled = false
        require("ui/uimanager"):nextTick(function()
            if not cancelled then cb(cached) end
        end)
        return { cancel = function() cancelled = true end }
    end
    return fetchTocAsync(self, identity, cb)
end

Source.refreshTocAsync = fetchTocAsync

---@param url string
---@param cb fun(data: string|nil, err: any)
---@return { cancel: fun() }|nil
local function downloadImage(url, cb)
    return Request.get(url, {
        accept = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
        headers = {
            ["Referer"] = "https://e.m.jd.com/",
        },
        timeout = require("http.timeout").net(3),
        allow_redirects = true,
    }, function(raw, err)
        if not raw or raw == "" then
            logger.dbg("jdread image download failed", url, err)
            cb(nil, err)
        else
            cb(raw)
        end
    end)
end

---@param self JdreadSource
---@param identity BookIdentity
---@param chapter BookChapter
---@param cb fun(payload: ChapterContentPayload|nil, err: string|nil)
---@return CancelHandle|nil
local function fetchContent(self, identity, chapter, cb)
    local cancelled, fetch_job, asset_job, cover = false, nil, nil, nil
    local done = function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        local payload = Mapper.content(wire, chapter.title, cover)
        if not payload then
            cb(nil, err or _("京东读书网页协议读不到本章，请在京东读书 App 内阅读"))
            return
        end
        asset_job = Assets.localizeAsync(
            payload.html,
            Paths.bookWorkDir(identity.stable_id, "jdread") .. "/images",
            downloadImage,
            function(html)
                if cancelled then return end
                payload.html = html
                cb(payload)
            end
        )
    end
    -- 调用方手里的 chapter 可能来自失效目录，uid 只从有效目录按 idx 取。
    local function download(toc)
        local target = toc[chapter.idx]
        if not target then cb(nil, _("缺少章节信息")); return end
        cover = target.cover
        local query = DOWNLOAD_QUERY[toc[1].toc_version](target.uid)
        fetch_job = self._client:downloadChapterAsync(identity.stable_id, query, done)
    end
    local toc = currentToc(self, identity)
    if toc then
        download(toc)
    else
        fetch_job = self:loadTocAsync(identity, function(fresh, err)
            if cancelled then return end
            if not fresh then cb(nil, err); return end
            download(fresh)
        end)
    end
    return { cancel = function()
            cancelled = true
            if fetch_job then fetch_job.cancel() end
            if asset_job then asset_job.cancel() end
        end }
end

--- 绑定实例的正文下载函数，供 source.chapter 调用。
---@param self JdreadSource
---@return ChapterFetchContent
local function contentFetcher(self)
    return function(ref, chapter, done)
        return fetchContent(self, ref, chapter, done)
    end
end

--- 旧目录一条一章，带锚点小节的书改成按文件成章后章号错位，已缓存的章节文件会对不上。
--- 开书前（书还没打开，删章节文件安全）在线比一次章数：变了就清整本缓存，没变的旧缓存照用。
---@param self JdreadSource
---@param identity BookIdentity
---@param cb fun()
---@return { cancel: fun() }|nil
local function migrateLayout(self, identity, cb)
    local old = Toc.read(self.id, identity.stable_id)
    if old == nil then
        local payload = require("book.books_db").getToc(self.id, identity.stable_id)
        -- 不看 TTL 的原始目录；坏 JSON 等同没有旧目录。
        local ok, list = pcall(require("json").decode, payload or "")
        old = ok and type(list) == "table" and list or nil
    end
    if not old or #old == 0 or self:isTocCurrent(old)
        or not require("ui/network/manager"):isConnected() then
        cb()
        return nil
    end
    return fetchTocAsync(self, identity, function(toc)
        if toc and #toc ~= #old then
            require("book.store").clearCache(self.id, identity.stable_id)
        end
        cb()
    end)
end

---@param identity BookIdentity
---@param opts table|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:openBookAsync(identity, opts, cb)
    local cancelled, open_job = false, nil
    local migrate_job = migrateLayout(self, identity, function()
        if cancelled then return end
        open_job = require("source.chapter").openWithUi(self, identity, identity.book, opts, {
            loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
            fetchContent = contentFetcher(self),
        }, cb)
    end)
    return { cancel = function()
            cancelled = true
            if migrate_job then migrate_job.cancel() end
            if open_job then open_job.cancel() end
        end }
end

---@param identity BookIdentity
---@param toc BookChapter[]
---@param from_idx integer
---@param count integer
---@param cb fun()|nil
---@return { cancel: fun() }
function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = contentFetcher(self),
    }, cb)
end

--- 缓存整本章节正文；已落盘章节由公共实现自动跳过。
---@param identity BookIdentity
---@param on_progress fun(done: integer, total: integer)|nil
---@param cb fun(ok: boolean, cached: integer, err: string|nil, total: integer, failed: integer)
---@return { cancel: fun() }
function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    return require("source.chapter").cacheAllAsync(self, identity, contentFetcher(self), on_progress, cb,
        nil, range)
end

--- 拉取云端进度，以章节 uid（对不上时用标题）映射本地连续章节号。
---@param identity BookIdentity
---@param cb fun(pos: ProgressPosition|nil, err: string|nil, meta: table|nil)
---@return { cancel: fun() }
function Source:getProgressAsync(identity, cb)
    local cancelled, toc_job
    local request = self._client:getProgressAsync(identity.stable_id, function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        local pos, uid = Mapper.progress(wire)
        if not pos then cb(nil, nil, { empty = true }); return end
        --- 按 uid 定位章节；JD 上报的 chapter_id 常对不上本地目录 uid，再按标题兜底。
        ---@param toc BookChapter[]|nil
        local function locate(toc)
            local idx = toc and Toc.index(identity.source_id, identity.stable_id, uid)
            if not idx and pos.chapter_title then
                for _idx, chapter in ipairs(toc or {}) do
                    if chapter.title == pos.chapter_title then
                        idx = chapter.idx
                        uid = chapter.uid
                        break
                    end
                end
            end
            if idx then
                pos.chapter_idx = idx
                pos.extra = { chapter_uid = uid, chapter_idx = idx }
            end
            cb(pos)
        end
        local toc = currentToc(self, identity)
        if toc then locate(toc); return end
        toc_job = self:loadTocAsync(identity, function(fresh)
            if cancelled then return end
            locate(fresh)
        end)
    end)
    return { cancel = function()
            cancelled = true
            request.cancel()
            if toc_job then toc_job.cancel() end
        end }
end

--- 推送全书比例和当前章节 uid。本地章节 HTML 与京东段落坐标不对应，故从章节起点恢复。
---@param identity BookIdentity
---@param pos ProgressPosition
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Source:putProgressAsync(identity, pos, cb)
    local cancelled, toc_job, push_job
    local chapter_idx = pos.chapter_idx or identity.chapter_idx

    local function push(toc)
        local chapter = chapter_idx and toc[chapter_idx]
        if not chapter then cb(nil, _("缺少章节信息")); return end
        push_job = self._client:putProgressAsync(identity.stable_id, {
            action = "create",
            data_type = 0,
            force = 2,
            para_idx = 0,
            offset_in_para = 0,
            chapter_id = chapter.uid,
            epub_chapter_title = pos.chapter_title or chapter.title,
            quote_text = "",
            percent = Progress.clampFraction(pos.fraction),
            created_at = os.time(),
        }, function(wire, err)
            if cancelled then return end
            cb(wire and true or nil, err)
        end)
    end

    local toc = currentToc(self, identity)
    if toc then
        push(toc)
    else
        toc_job = self:loadTocAsync(identity, function(value, err)
            if cancelled then return end
            if not value then cb(nil, err); return end
            push(value)
        end)
    end
    return { cancel = function()
            cancelled = true
            if toc_job then toc_job.cancel() end
            if push_job then push_job.cancel() end
        end }
end

return Jdread
