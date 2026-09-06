--[[--
京东读书数据源门面。

@module koplugin.book.source.jdread
--]]

local Client = require("source.jdread.client")
local Mapper = require("source.jdread.mapper")
local Toc = require("source.jdread.toc")
local BookListResult = require("types.book_list")
local SourceBase = require("source.base")
local ProgressPosition = require("types.book_progress")
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
        store = true,
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

---@param _opts table|nil
---@param cb fun(result: SyncResult|nil, err: string|nil)
---@return { cancel: fun() }
function Source:syncBooksAsync(_opts, cb)
    return self._client:shelfSyncAsync(function(wire, err)
        if not wire then cb(nil, err); return end
        local list = Mapper.shelfList(wire, function(id, url)
            self._covers[id] = url
        end)
        local result, reconcile_err = require("book.store").reconcile(self.id, list.data or {})
        cb(result, reconcile_err)
    end)
end

--- 京东书城：关键词走搜索；空关键词聚合书架前十本书的相关推荐。
---@param opts BookListOpts|nil
---@param cb fun(data: BookListResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:listStoreAsync(opts, cb)
    opts = opts or {}
    local search = opts.search or ""
    local function map(wire, err)
        if not wire then cb(nil, err); return end
        cb(Mapper.storeList(wire, function(id, url)
            self._covers[id] = url
        end))
    end
    if search ~= "" then
        return self._client:searchAsync(search, opts.page, opts.page_size, map)
    end

    local cancelled, active = false, nil
    active = self._client:shelfSyncAsync(function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        local rows = wire.data and wire.data.books or {}
        local wanted = math.max(1, math.floor(tonumber(opts.page_size) or 20))
        local seed_ids, seen, books = {}, {}, {}
        for _, row in ipairs(rows) do
            local book = Mapper.book(row)
            if book then
                seen[book.stable_id] = true
                if #seed_ids < 10 then seed_ids[#seed_ids + 1] = book.stable_id end
            end
        end
        local seed_index, first_err = 0, nil
        local function nextSeed()
            if cancelled then return end
            seed_index = seed_index + 1
            if seed_index > #seed_ids or #books >= wanted then
                if #books == 0 and first_err then cb(nil, first_err); return end
                cb(BookListResult.new(books, #books))
                return
            end
            active = self._client:recommendAsync(seed_ids[seed_index], function(recommended, recommend_err)
                if cancelled then return end
                if recommended then
                    local result = Mapper.storeList(recommended, function(id, url)
                        self._covers[id] = url
                    end)
                    for _, book in ipairs(result.data or {}) do
                        if #books >= wanted then break end
                        if not seen[book.stable_id] then
                            seen[book.stable_id] = true
                            books[#books + 1] = book
                        end
                    end
                else
                    first_err = first_err or recommend_err
                end
                nextSeed()
            end)
        end
        nextSeed()
    end)
    return {
        cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end,
    }
end

--- 将书城书籍加入京东书架，再以远端书架收敛本地图书馆。
---@param book Book|nil
---@param cb fun(ok: boolean|nil, err: string|nil, title: string|nil)
---@return { cancel: fun() }|nil
function Source:addStoreBookAsync(book, cb)
    local book_id = book and book.stable_id
    if type(book_id) ~= "string" or book_id == "" then
        cb(nil, _("无效书籍"))
        return nil
    end
    local cancelled, active = false, nil
    active = self._client:addToShelfAsync(book_id, function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        active = self:syncBooksAsync(nil, function(result, sync_err)
            if cancelled then return end
            if not result then cb(nil, sync_err); return end
            cb(true, nil, book.title)
        end)
    end)
    return {
        cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end,
    }
end

---@param identity BookIdentity
---@param cb fun(book: Book|nil, err: string|nil)
---@return { cancel: fun() }
function Source:getDetailAsync(identity, cb)
    return self._client:bookInfoAsync(identity.stable_id, function(wire, err)
        if not wire then cb(nil, err); return end
        local book, cover = Mapper.book(wire.data or wire)
        if not book then cb(nil, _("书籍详情为空")); return end
        if cover then self._covers[book.stable_id] = cover end
        local existing = require("db.book").get(self.id, book.stable_id)
        if existing then book.percent = existing.percent end
        require("book.store").rememberMany({ book })
        cb(book)
    end)
end

---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:loadTocAsync(identity, cb)
    local cached = Toc.read(identity.source_id, identity.stable_id)
    if cached and #cached > 0 then
        require("ui/uimanager"):nextTick(function() cb(cached) end)
        return nil
    end
    return self._client:chapterInfosAsync(identity.stable_id, function(wire, err)
        if not wire then cb(nil, err); return end
        local chapters = Mapper.chapters(wire)
        if not chapters then cb(nil, _("章节列表为空")); return end
        Toc.put(identity.source_id, identity.stable_id, chapters)
        cb(chapters)
    end)
end

---@param self JdreadSource
---@param identity BookIdentity
---@param chapter BookChapter
---@param cb fun(payload: ChapterContentPayload|nil, err: string|nil)
---@return { cancel: fun() }
local function fetchContent(self, identity, chapter, cb)
    return self._client:chapterContentAsync(identity.stable_id, chapter.uid, function(wire, err)
        if not wire then cb(nil, err); return end
        local payload = Mapper.content(wire, chapter.title)
        if not payload then cb(nil, _("章节内容为空")); return end
        cb(payload)
    end)
end

---@param identity BookIdentity
---@param opts table|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:openBookAsync(identity, opts, cb)
    return require("source.chapter").openWithUi(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = function(ref, chapter, done)
            return fetchContent(self, ref, chapter, done)
        end,
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
        fetchContent = function(ref, chapter, done)
            return fetchContent(self, ref, chapter, done)
        end,
    }, cb)
end

--- 缓存整本章节正文；已落盘章节由公共实现自动跳过。
---@param identity BookIdentity
---@param on_progress fun(done: integer, total: integer)|nil
---@param cb fun(ok: boolean, cached: integer, err: string|nil, total: integer, failed: integer)
---@return { cancel: fun() }
function Source:cacheAllChaptersAsync(identity, on_progress, cb)
    local cancelled, active = false, nil
    active = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then cb(false, 0, err or _("章节列表为空"), 0, 0); return end
        active = require("source.chapter").prefetchAsync(identity, nil, toc, 0, #toc, {
            fetchContent = function(ref, chapter, done)
                return fetchContent(self, ref, chapter, done)
            end,
            persist_toc = false,
            persist_book = false,
            progress = on_progress,
            interval_seconds = 1.5,
        }, function(cached, total, failed, last_err)
            if not cancelled then
                cb(failed == 0, cached, last_err, total, failed)
            end
        end)
    end)
    return {
        cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end,
    }
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
        local idx = Toc.index(identity.source_id, identity.stable_id, uid)
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
    return {
        cancel = function()
            cancelled = true
            if request and request.cancel then request.cancel() end
            if toc_job and toc_job.cancel then toc_job.cancel() end
        end,
    }
end

--- 推送全书比例和当前 catalogId。旧正文协议没有稳定段落坐标，故从章节起点恢复。
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
            percent = ProgressPosition.clampFraction(pos.fraction),
            created_at = os.time(),
        }, function(wire, err)
            if cancelled then return end
            cb(wire and true or nil, err)
        end)
    end

    local toc = Toc.read(identity.source_id, identity.stable_id)
    if toc then
        push(toc)
    else
        toc_job = self:loadTocAsync(identity, function(value, err)
            if cancelled then return end
            if not value then cb(nil, err); return end
            push(value)
        end)
    end
    return {
        cancel = function()
            cancelled = true
            if toc_job and toc_job.cancel then toc_job.cancel() end
            if push_job and push_job.cancel then push_job.cancel() end
        end,
    }
end

return Jdread
