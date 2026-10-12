--[[--
京东读书数据源门面。

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
local Progress = require("book.progress")
local logger = require("utils.log")
local _ = require("gettext")

local Jdread = {}

---@return BookSourceMeta
function Jdread.meta()
    return { id = "jdread", name = _("京东读书"), type = "chapter" }
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

---@param identity BookIdentity
---@param cb fun(book: Book|nil, err: string|nil)
---@return CancelHandle|nil
function Source:getDetailAsync(identity, cb)
    return self._client:bookInfoAsync(identity.stable_id, function(wire, err)
        if not wire then cb(nil, err); return end
        if type(wire.data) ~= "table" then cb(nil, _("书籍详情为空")); return end
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
        timeout = 90,
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
