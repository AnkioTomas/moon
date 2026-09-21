--[[--
京东读书数据源门面。

@module koplugin.book.source.jdread
--]]

local Client = require("source.jdread.client")
local Mapper = require("source.jdread.mapper")
local Toc = require("source.jdread.toc")
local SourceBase = require("source.base")
local Progress = require("book.progress")
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
---@param identity BookIdentity
---@param cb fun(ok: boolean, err: string|nil)
---@return table
function Source:deleteBookAsync(identity, cb)
    local Store = require("book.store")
    if not Store.markDeleted(self.id, identity.stable_id) then
        require("ui/uimanager"):nextTick(function()
            cb(false, _("删除本书失败"))
        end)
        return { cancel = function() end }
    end
    local cancelled, job = false, nil
    require("ui/uimanager"):nextTick(function()
        if not cancelled then cb(true) end
    end)
    require("ui/network/manager"):runWhenOnline(function()
        if cancelled then return end
        job = self._client:removeFromShelfAsync(identity.stable_id, function(wire)
            if cancelled then return end
            if wire then Store.finalizeDeleted(self.id, identity.stable_id) end
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
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

--- 本地已标删：推云端 remove，成功则撕墓碑。
---@param self JdreadSource
---@param cb fun(pushed: integer)
---@return { cancel: fun() }|nil
local function pushDeletedMembers(self, cb)
    local Store = require("book.store")
    local pending = require("db.book").pendingDeleteIds(self.id)
    if #pending == 0 then
        cb(0)
        return nil
    end
    local cancelled, job, pushed, index = false, nil, 0, 0
    local function nextDelete()
        if cancelled then return end
        index = index + 1
        if index > #pending then
            cb(pushed)
            return
        end
        local stable_id = pending[index]
        job = self._client:removeFromShelfAsync(stable_id, function(wire)
            if cancelled then return end
            if wire then
                Store.finalizeDeleted(self.id, stable_id)
                pushed = pushed + 1
            end
            nextDelete()
        end)
    end
    nextDelete()
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job:cancel() end
    end }
end

--- 书架成员上行：remote_ids 非 nil 时推「本地有、远端无」；nil 时推全部脏加架行。
---@param self JdreadSource
---@param remote_ids table<string, boolean>|nil
---@param cb fun(pushed: integer)
---@return { cancel: fun() }|nil
local function pushMissingShelfMembers(self, remote_ids, cb)
    local BookDB = require("db.book")
    local missing = {}
    if remote_ids then
        for _, stable_id in ipairs(BookDB.libraryStableIdsBySource(self.id)) do
            if not remote_ids[stable_id] then
                missing[#missing + 1] = stable_id
            end
        end
    else
        missing = BookDB.pendingShelfAddIds(self.id)
    end
    if #missing == 0 then
        cb(0)
        return nil
    end
    local cancelled, job, pushed, index = false, nil, 0, 0
    local function nextMissing()
        if cancelled then return end
        index = index + 1
        if index > #missing then
            cb(pushed)
            return
        end
        local stable_id = missing[index]
        job = self._client:addToShelfAsync(stable_id, function(wire)
            if cancelled then return end
            if wire then
                pushed = pushed + 1
                if remote_ids then remote_ids[stable_id] = true end
                BookDB.markSynced(self.id, stable_id)
            end
            nextMissing()
        end)
    end
    nextMissing()
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job:cancel() end
    end }
end

---@param opts { dirty_only?: boolean, force?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: string|nil)
---@return { cancel: fun() }
function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    local cancelled, job, push_job, delete_job = false, nil, nil, nil
    if opts.dirty_only then
        delete_job = pushDeletedMembers(self, function(deleted_n)
            if cancelled then return end
            push_job = pushMissingShelfMembers(self, nil, function(pushed)
                if cancelled then return end
                cb({
                    pulled = 0,
                    pushed = (deleted_n or 0) + (pushed or 0),
                    hidden = 0,
                    conflicts = 0,
                    skipped = false,
                })
            end)
        end)
        return { cancel = function()
            cancelled = true
            if push_job and push_job.cancel then push_job:cancel() end
            if delete_job and delete_job.cancel then delete_job:cancel() end
        end }
    end
    local function pullAndReconcile(pushed)
        if cancelled then return end
        job = self._client:shelfSyncAsync(function(wire, err)
            if cancelled then return end
            if not wire then cb(nil, err); return end
            local list = Mapper.shelfList(wire, function(id, url)
                self._covers[id] = url
            end)
            local result, reconcile_err = require("book.store").reconcile(self.id, list.data or {})
            if result then result.pushed = pushed or 0 end
            cb(result, reconcile_err)
        end)
    end
    local function afterDeletes(deleted_n)
        if cancelled then return end
        job = self._client:shelfSyncAsync(function(wire, err)
            if cancelled then return end
            if not wire then cb(nil, err); return end
            local list = Mapper.shelfList(wire, function(id, url)
                self._covers[id] = url
            end)
            local remote_ids = {}
            for _, book in ipairs(list.data or {}) do
                if book.stable_id then remote_ids[tostring(book.stable_id)] = true end
            end
            push_job = pushMissingShelfMembers(self, remote_ids, function(pushed)
                if cancelled then return end
                local total = (deleted_n or 0) + (pushed or 0)
                if pushed > 0 then
                    pullAndReconcile(total)
                    return
                end
                local result, reconcile_err = require("book.store").reconcile(self.id, list.data or {})
                if result then result.pushed = total end
                cb(result, reconcile_err)
            end)
        end)
    end
    delete_job = pushDeletedMembers(self, afterDeletes)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job:cancel() end
        if push_job and push_job.cancel then push_job:cancel() end
        if delete_job and delete_job.cancel then delete_job:cancel() end
    end }
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

---@param identity BookIdentity
---@return boolean
local function useDownload(identity)
    local toc = Toc.read(identity.source_id, identity.stable_id)
    return toc ~= nil and toc[1] ~= nil and toc[1].toc_version == 2
end

---@param self JdreadSource
---@param identity BookIdentity
---@param chapter BookChapter
---@param cb fun(payload: ChapterContentPayload|nil, err: string|nil)
---@return CancelHandle|nil
local function fetchContent(self, identity, chapter, cb)
    local done = function(wire, err)
        if not wire then cb(nil, err); return end
        local payload = Mapper.content(wire, chapter.title)
        if not payload then
            cb(nil, err or _("京东读书无可用阅读权限"))
            return
        end
        cb(payload)
    end
    if useDownload(identity) then
        return self._client:downloadChapterAsync(identity.stable_id, chapter.uid, done)
    end
    return self._client:chapterContentAsync(identity.stable_id, chapter.uid, done)
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
    return { cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end }
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
        if not idx and pos.chapter_title then
            local toc = Toc.read(identity.source_id, identity.stable_id)
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
            percent = Progress.clampFraction(pos.fraction),
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
    return { cancel = function()
            cancelled = true
            if toc_job and toc_job.cancel then toc_job.cancel() end
            if push_job and push_job.cancel then push_job.cancel() end
        end }
end

return Jdread
