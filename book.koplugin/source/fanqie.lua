--[[--
番茄小说官方数据源。

登录使用番茄 passport Web 二维码；书架、目录、正文和阅读进度均走
fanqienovel.com 官方接口，不接第三方正文代理。

@module koplugin.book.source.fanqie
--]]

require("l10n").apply()
local Client = require("source.fanqie.client")
local Mapper = require("source.fanqie.mapper")
local Toc = require("source.fanqie.toc")
local SourceBase = require("source.base")
local ProgressPosition = require("types.book_progress")
local _ = require("gettext")

local Fanqie = {}

---@return BookSourceMeta
function Fanqie.meta()
    return { id = "fanqie", name = _("番茄小说"), type = "chapter" }
end

---@class FanqieSource : SourceBase
---@field _client FanqieClient
---@field _covers table<string, string>
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return FanqieSource
function Fanqie.new()
    local cfg = require("utils.settings").getSource("fanqie")
    local meta = Fanqie.meta()
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
        search = false,
        refresh = true,
        scrape = false,
        edit = false,
        insight = true,
        stats_pull = false,
        store = false,
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
    local url = self._covers[identity.stable_id] or (identity.book and identity.book.cover)
    if type(url) ~= "string" or not url:match("^https?://") then
        return nil, _("无封面")
    end
    return { url = url }
end

---@param _opts table|nil
---@param cb fun(result: SyncResult|nil, err: string|nil)
---@return table
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

---@param identity BookIdentity
---@param cb fun(book: Book|nil, err: string|nil)
---@return table
function Source:getDetailAsync(identity, cb)
    return self._client:bookInfoAsync(identity.stable_id, function(wire, err)
        if not wire then cb(nil, err); return end
        local book, cover = Mapper.detail(wire, identity.stable_id)
        if not book then cb(nil, _("番茄小说书籍信息为空")); return end
        local existing = require("db.book").get(self.id, book.stable_id)
        if existing then
            book.percent = existing.percent
            book.in_library = existing.in_library
        end
        if cover then self._covers[book.stable_id] = cover end
        require("book.store").rememberMany({ book })
        cb(book)
    end)
end

---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return table
function Source:loadTocAsync(identity, cb)
    local cached = Toc.read(identity.source_id, identity.stable_id)
    if cached and #cached > 0 then
        require("ui/uimanager"):nextTick(function() cb(cached) end)
        return { cancel = function() end }
    end
    return self._client:directoryAsync(identity.stable_id, function(wire, err)
        if not wire then cb(nil, err); return end
        local chapters = Mapper.chapters(wire)
        if not chapters then cb(nil, _("番茄小说目录为空")); return end
        Toc.put(identity.source_id, identity.stable_id, chapters)
        cb(chapters)
    end)
end

---@param self FanqieSource
---@param identity BookIdentity
---@param chapter BookChapter
---@param cb fun(payload: ChapterContentPayload|nil, err: string|nil)
---@return table
local function fetchContent(self, identity, chapter, cb)
    return self._client:contentAsync(identity.stable_id, tostring(chapter.uid or ""), function(wire, err)
        if not wire then cb(nil, err); return end
        local payload = Mapper.content(wire, chapter.title)
        if not payload then cb(nil, _("番茄小说章节内容为空")); return end
        cb(payload)
    end)
end

---@param identity BookIdentity
---@param opts table|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return table
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
---@return table
function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = function(ref, chapter, done)
            return fetchContent(self, ref, chapter, done)
        end,
    }, cb)
end

---@param identity BookIdentity
---@param on_progress fun(done: integer, total: integer)|nil
---@param cb fun(ok: boolean, cached: integer, err: string|nil, total: integer, failed: integer)
---@return table
function Source:cacheAllChaptersAsync(identity, on_progress, cb)
    local cancelled, active = false, nil
    active = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then cb(false, 0, err, 0, 0); return end
        active = require("source.chapter").prefetchAsync(identity, nil, toc, 0, #toc, {
            fetchContent = function(ref, chapter, done)
                return fetchContent(self, ref, chapter, done)
            end,
            persist_toc = false,
            persist_book = false,
            progress = on_progress,
            interval_seconds = 1.5,
        }, function(cached, total, failed, last_err)
            if not cancelled then cb(failed == 0, cached, last_err, total, failed) end
        end)
    end)
    return { cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end }
end

---@param identity BookIdentity
---@param cb fun(pos: ProgressPosition|nil, err: string|nil, meta: table|nil)
---@return table
function Source:getProgressAsync(identity, cb)
    if not self:configured() then
        require("ui/uimanager"):nextTick(function() cb(nil, nil, { empty = true }) end)
        return { cancel = function() end }
    end
    local cancelled, toc_job
    local request = self._client:progressAsync(function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        local pos, uid, source_index = Mapper.progress(wire)
        if not pos then cb(nil, nil, { empty = true }); return end
        local function finish()
            if cancelled then return end
            local idx = uid and Toc.index(identity.source_id, identity.stable_id, uid)
            if not idx and source_index ~= nil then
                idx = tonumber(source_index)
                if idx == 0 then idx = 1 end
            end
            pos.chapter_idx = idx
            if uid then pos.extra = { chapter_uid = uid, chapter_idx = idx } end
            cb(pos)
        end
        local idx = uid and Toc.index(identity.source_id, identity.stable_id, uid)
        if idx or not uid then
            finish()
        else
            toc_job = self:loadTocAsync(identity, function(toc, toc_err)
                if cancelled then return end
                if not toc then cb(nil, toc_err); return end
                finish()
            end)
        end
    end)
    return { cancel = function()
            cancelled = true
            if request and request.cancel then request.cancel() end
            if toc_job and toc_job.cancel then toc_job.cancel() end
        end }
end

---@param identity BookIdentity
---@param pos ProgressPosition
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return table
function Source:putProgressAsync(identity, pos, cb)
    if not self:configured() then
        cb(nil, _("请先扫码登录番茄小说"))
        return { cancel = function() end }
    end
    pos = pos or {}
    local chapter_idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
    if not chapter_idx then cb(nil, _("缺少章节信息")); return { cancel = function() end } end
    local toc = Toc.read(identity.source_id, identity.stable_id)
    if not toc then
        local cancelled, toc_job
        toc_job = self:loadTocAsync(identity, function(value, err)
            if cancelled then return end
            if not value then cb(nil, err); return end
            local chapter = value[chapter_idx]
            if not chapter then cb(nil, _("缺少章节信息")); return end
            local uid = chapter.uid
            local index = tonumber(chapter.source_idx) or chapter_idx - 1
            local request = self._client:updateProgressAsync(identity.stable_id, uid, index,
                ProgressPosition.clampFraction(pos.fraction) * 10000, function(wire, push_err)
                    if cancelled then return end
                    cb(wire and true or nil, push_err)
                end)
            toc_job = { cancel = function() cancelled = true; if request.cancel then request:cancel() end end }
        end)
        return { cancel = function() cancelled = true; if toc_job and toc_job.cancel then toc_job.cancel() end end }
    end
    local chapter = toc[chapter_idx]
    if not chapter then cb(nil, _("缺少章节信息")); return { cancel = function() end } end
    local uid = chapter.uid
    local index = tonumber(chapter.source_idx) or chapter_idx - 1
    return self._client:updateProgressAsync(identity.stable_id, uid, index,
        ProgressPosition.clampFraction(pos.fraction) * 10000, function(wire, err)
            cb(wire and true or nil, err)
        end)
end

return Fanqie
