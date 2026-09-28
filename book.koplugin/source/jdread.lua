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
---@field _covers table<string, string>
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
        _client = Client:new(cfg),
        _covers = {},
    }, Source)
end

---@return SourceCapabilities
function Source:capabilities()
    return {
        search = true,
        refresh = true,
        scrape = false,
        edit = false,
        insight = true,
        stats_pull = false,
    }
end

---@return boolean
function Source:configured()
    return self._client:configured()
end

function Source:clearCaches()
    self._covers = {}
    Toc.clear()
end

function Source:close()
    self._covers = {}
end

--- 删除：本地先标 deleted，能上网时再推云端真删。
Source.deleteBookAsync = Shelf.deleteAsync

---@param identity BookIdentity
---@return BookCoverRequest|nil, string|nil
function Source:coverRequest(identity)
    local url = self._covers[identity.stable_id]
        or (identity.book and identity.book.cover)
    if type(url) ~= "string" or not url:match("^https?://") then
        return nil, _("无封面")
    end
    return { url = url }
end

---@param opts { dirty_only?: boolean, force?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: string|nil)
---@return { cancel: fun() }
function Source:syncBooksAsync(opts, cb)
    return Shelf.syncAsync(self, opts, cb, function(id, url)
        self._covers[id] = url
    end, Mapper.shelfList)
end

---@param identity BookIdentity
---@param cb fun(book: Book|nil, err: string|nil)
---@return CancelHandle|nil
function Source:getDetailAsync(identity, cb)
    return self._client:bookInfoAsync(identity.stable_id, function(wire, err)
        if not wire then cb(nil, err); return end
        local book, cover = Mapper.book(wire.data or wire)
        if not book then cb(nil, _("书籍详情为空")); return end
        if cover then self._covers[book.stable_id] = cover end
        local existing = require("db.book").get(self.id, book.stable_id)
        if existing then
            book.deleted = existing.deleted
        end
        local progress = require("db.progress").get(self.id, book.stable_id)
        if progress then
            book.percent = require("book.progress").clampPercent(progress.fraction, false, true)
        end
        require("book.store").rememberMany({ book })
        cb(book)
    end)
end

--- 目录版本 → download/chapter 查询参数（见 Mapper.chapters）。
local DOWNLOAD_QUERY = {
    [2] = function(uid) return { indexes = uid } end,
    [3] = function(uid) return { type = 1, ids = uid } end,
}

--- 只认下载协议目录；旧 cread 目录（版本 1）与无版本目录一律失效。
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
        block_timeout = 90,
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
    local cancelled, fetch_job, asset_job = false, nil, nil
    local done = function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        local payload = Mapper.content(wire, chapter.title)
        if not payload then
            cb(nil, err or _("京东读书无可用阅读权限"))
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
            if fetch_job and fetch_job.cancel then fetch_job.cancel() end
            if asset_job and asset_job.cancel then asset_job.cancel() end
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

---@param identity BookIdentity
---@param opts table|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:openBookAsync(identity, opts, cb)
    return require("source.chapter").openWithUi(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = contentFetcher(self),
    }, cb)
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
function Source:cacheAllChaptersAsync(identity, on_progress, cb)
    return require("source.chapter").cacheAllAsync(self, identity, contentFetcher(self), on_progress, cb)
end

--- 拉取云端进度，以 catalogId 映射本地连续章节号。
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
        local toc = currentToc(self, identity)
        local idx = toc and Toc.index(identity.source_id, identity.stable_id, uid)
        if not idx and pos.chapter_title then
            for _, chapter in ipairs(toc or {}) do
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
            cb(pos)
            return
        end
        toc_job = self:loadTocAsync(identity, function()
            if cancelled then return end
            idx = Toc.index(identity.source_id, identity.stable_id, uid)
            pos.chapter_idx = idx
            if idx then pos.extra = { chapter_uid = uid, chapter_idx = idx } end
            cb(pos)
        end)
    end)
    return { cancel = function()
            cancelled = true
            if request and request.cancel then request.cancel() end
            if toc_job and toc_job.cancel then toc_job.cancel() end
        end }
end

--- 推送全书比例和当前章节 uid。本地章节 HTML 与京东段落坐标不对应，故从章节起点恢复。
---@param identity BookIdentity
---@param pos ProgressPosition
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Source:putProgressAsync(identity, pos, cb)
    pos = pos or {}
    local cancelled, toc_job, push_job
    local chapter_idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx) or 1

    local function push(toc)
        local chapter = toc and toc[chapter_idx]
        local uid = Toc.uid(identity.source_id, identity.stable_id, chapter_idx)
        if not uid then cb(nil, _("缺少章节信息")); return end
        push_job = self._client:putProgressAsync(identity.stable_id, {
            action = "create",
            data_type = 0,
            force = 2,
            para_idx = 0,
            offset_in_para = 0,
            chapter_id = uid,
            epub_chapter_title = pos.chapter_title or (chapter and chapter.title) or "",
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
            if toc_job and toc_job.cancel then toc_job.cancel() end
            if push_job and push_job.cancel then push_job.cancel() end
        end }
end

return Jdread
