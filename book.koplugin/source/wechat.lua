--[[--
微信读书数据源门面（仅异步网络）

@module koplugin.book.source.wechat
--]]

local Auth = require("source.wechat.auth")
local Client = require("source.wechat.client")
local Mapper = require("source.wechat.mapper")
local WChapter = require("source.wechat.chapter")
local Report = require("source.wechat.report")
local Notes = require("source.wechat.notes")
local SourceBase = require("source.base")
local ProgressPosition = require("types.book_progress")
local logger = require("logger")
local _ = require("gettext")

local TOC_TTL = 6 * 60 * 60

local WeChat = {}

--- 返回微信读书源元信息。
---@return BookSourceMeta
function WeChat.meta()
    return { id = "wechat", name = _("微信读书"), type = "chapter" }
end

---@class WechatSource : SourceBase
---@field cfg table
---@field _client table
---@field _covers table<string, string>
---@field _reporter table
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

--- 构造微信读书源实例。
---@return WechatSource
function WeChat.new()
    local cfg = require("utils.settings").getSource("wechat")
    local meta = WeChat.meta()
    local client = Client:new(cfg)
    ---@type WechatSource
    local self = setmetatable({
        id = meta.id,
        name = meta.name,
        type = meta.type,
        cfg = cfg,
        _client = client,
        _covers = {},
        _reporter = Report.new(client),
    }, Source)
    return self
end

--- 缓存书籍封面 URL（仅接受 http(s)）。
---@param self WechatSource
---@param stable_id string
---@param url string
local function rememberCover(self, stable_id, url)
    if type(stable_id) == "string" and type(url) == "string" and url:find("^https?://", 1) then
        self._covers[stable_id] = url
    end
end

--- 书架同步后把远端进度写入 pending_progress（不覆盖本地脏进度）。
---@param self WechatSource
---@param shelf table
---@param cb fun()|nil
local function importShelfProgress(self, shelf, cb)
    local rows = Mapper.shelfProgressRows(shelf)
    if #rows == 0 then
        if cb then cb() end
        return
    end
    require("utils.db.queue").run(function()
        local ProgressDB = require("utils.db.progress")
        for _, row in ipairs(rows) do
            ProgressDB.upsertRemote(self.id, row.stable_id, {
                fraction = row.fraction,
                chapter_uid = row.chapter_uid,
            })
        end
    end, {
        on_done = cb,
        on_failed = function(err)
            logger.warn("wechat shelf progress import failed", err)
            if cb then cb() end
        end,
    })
end

--- 返回微信读书源能力集。
---@return SourceCapabilities
function Source:capabilities()
    return {
        search = true,
        refresh = true,
        scrape = false,
        edit = false,
        insight = true,
        store = true,
    }
end

--- 是否已登录微信读书。
---@return boolean
function Source:configured()
    return Auth.hasSession()
end

--- 清空封面 URL 缓存。
function Source:clearCaches()
    self._covers = {}
    require("source.wechat.context").clear()
end

--- 关闭微信源并清空封面缓存。
function Source:close()
    self._covers = {}
    require("source.wechat.context").clear()
end

--- 构造微信封面请求。
---@param identity BookIdentity
---@return BookCoverRequest|nil, string|nil
function Source:coverRequest(identity)
    local url = self._covers[identity.stable_id]
    if type(url) ~= "string" or url == "" then
        return nil, _("无封面")
    end
    return {
        url = url,
        headers = Client.sessionHeaders(),
    }
end

---@param _opts table|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return table
function Source:syncBooksAsync(_opts, cb)
    local cancelled, job = false, nil
    job = self._client:shelfSyncAsync(function(wire, err)
        if cancelled then return end
        if wire then
            local list = Mapper.shelfList(wire, function(id, url)
                rememberCover(self, id, url)
            end)
            job = require("book.store").reconcileAsync(self.id, list.data or {}, nil, function(result, rerr)
                if cancelled then return end
                if not result then
                    cb(nil, rerr)
                    return
                end
                importShelfProgress(self, wire, function()
                    if not cancelled then cb(result) end
                end)
            end)
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job:cancel() end
    end }
end

function Source:listStoreAsync(opts, cb)
    opts = opts or {}
    local search = opts.search or ""
    local on_wire = function(wire, err)
        if wire then
            cb(Mapper.searchList(wire, function(id, url)
                rememberCover(self, id, url)
            end))
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end
    if search == "" then
        return self._client:storeCatalogAsync({
            limit = opts.page_size or 20,
            category = opts.category or "all",
            rank = 1,
        }, on_wire)
    end
    return self._client:searchAsync(search, opts.page_size, opts.scope, on_wire)
end

--- 书城书加入微信读书书架，并同步到本地图书馆。
---@param book Book|nil
---@param cb fun(ok: boolean|nil, err: string|nil, title: string|nil)
---@return { cancel: fun() }|nil
function Source:addStoreBookAsync(book, cb)
    if not self:configured() then
        cb(nil, _("请先扫码登录微信读书"))
        return nil
    end
    local book_id = book and book.stable_id
    if type(book_id) ~= "string" or book_id == "" then
        cb(nil, _("无效书籍"))
        return nil
    end
    local cancelled, job = false, nil
    job = self._client:addToShelfAsync(book_id, function(wire, err)
        if cancelled then
            return
        end
        if not wire then
            cb(nil, err)
            return
        end
        job = self:syncBooksAsync(nil, function(result, sync_err)
            if cancelled then
                return
            end
            if not result then
                cb(nil, (type(sync_err) == "table" and sync_err.message) or sync_err)
                return
            end
            cb(true, nil, book and book.title)
        end)
    end)
    return {
        cancel = function()
            cancelled = true
            if job and job.cancel then
                job:cancel()
            end
        end,
    }
end

function Source:getDetailAsync(identity, cb)
    return self._client:bookInfoAsync(identity.stable_id, function(wire, err)
        if not wire then
            cb(nil, (type(err) == "table" and err.message) or err)
            return
        end
        local row = wire.book or wire.data or wire
        local b, cover = Mapper.book(row)
        if not b then
            cb(nil, _("书籍详情为空"))
            return
        end
        if cover then rememberCover(self, b.stable_id, cover) end
        cb(b)
    end)
end

local function getTocAsync(self, identity, cb)
    local payload = require("utils.db.toc").get(identity.source_id, identity.stable_id, TOC_TTL)
    if payload then
        local ok, cached = pcall(function() return require("json").decode(payload) end)
        if ok and type(cached) == "table" and #cached > 0 then
            require("ui/uimanager"):nextTick(function() cb(cached) end)
            return
        end
    end
    return self._client:chapterInfosAsync(identity.stable_id, function(wire, err)
        if not wire then
            cb(nil, (type(err) == "table" and err.message) or err)
            return
        end
        local chapters, cerr = Mapper.chapters(wire, identity.stable_id)
        if chapters then
            local ok, encoded = pcall(function() return require("json").encode(chapters) end)
            if ok and encoded then
                require("utils.db.queue").run(function()
                    require("utils.db.toc").upsert(identity.source_id, identity.stable_id, encoded)
                end)
            end
            cb(chapters)
        else
            cb(nil, _("章节列表为空"))
        end
    end)
end

local function fetchChapterContentAsync(_self, identity, chapter, cb)
    return WChapter.fetchContentAsync(identity.stable_id, chapter, function(payload, err)
        if payload then
            cb(payload)
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

function Source:openBookAsync(identity, opts, cb)
    return require("source.chapter").openWithUi(self, identity, identity.book, opts, {
        loadToc = function(r, done) return getTocAsync(self, r, done) end,
        fetchContent = function(r, chapter, done)
            return fetchChapterContentAsync(self, r, chapter, done)
        end,
    }, cb)
end

--- 阅读中后台预取后续章节。
---@param identity BookIdentity
---@param toc BookChapter[]
---@param from_idx integer
---@param count integer
---@param cb fun()|nil
---@return { cancel: fun() }
function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = function(r, chapter, done)
            return fetchChapterContentAsync(self, r, chapter, done)
        end,
    }, cb)
end

function Source:getProgressAsync(identity, cb)
    local cancelled = false
    local first, second
    first = self._client:getProgressAsync(identity.stable_id, function(wire, err)
        if cancelled then return end
        if not wire then
            cb(nil, (type(err) == "table" and err.message) or err)
            return
        end
        local pos, chapter_uid = Mapper.progress(wire)
        if not pos then
            cb(nil, _("进度为空"))
            return
        end
        pos.chapter_uid = chapter_uid
        if not chapter_uid or pos.chapter_idx then
            cb(pos)
            return
        end
        second = getTocAsync(self, identity, function(toc)
            if cancelled then return end
            for _, ch in ipairs(toc or {}) do
                if tostring(ch.uid) == tostring(chapter_uid) then
                    pos.chapter_idx = ch.idx
                    break
                end
            end
            cb(pos)
        end)
    end)
    return {
        cancel = function()
            cancelled = true
            if first then first.cancel() end
            if second then second.cancel() end
        end,
    }
end

function Source:putProgressAsync(identity, pos, cb)
    pos = pos or {}
    local frac = ProgressPosition.clampFraction(pos.fraction)
    local progress = math.max(0, math.min(100, math.floor(frac * 100 + 0.5)))
    local chapter_uid = pos.chapter_uid
    if not chapter_uid and pos.chapter_idx then
        local payload = require("utils.db.toc").get(identity.source_id, identity.stable_id, TOC_TTL)
        if payload then
            local ok, toc = pcall(function() return require("json").decode(payload) end)
            if ok and type(toc) == "table" then
                local ch = toc[tonumber(pos.chapter_idx) or 0]
                chapter_uid = ch and ch.uid
            end
        end
    end
    return self._client:putProgressAsync(identity.stable_id, progress, chapter_uid, function(wire, err)
        if wire then
            cb(true)
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

function Source:pushStatsAsync(rows, cb)
    if not self:configured() then
        cb(nil, _("请先扫码登录微信读书"))
        return nil
    end
    self._reporter:pushStatsRows(rows, cb)
    return nil
end

function Source:pullStatsAsync(cb)
    return self._client:readStatsAsync("monthly", nil, function(wire, err)
        if not wire then
            cb(nil, (type(err) == "table" and err.message) or err)
            return
        end
        local rows = {}
        local read_longest = wire.readLongest or wire.data and wire.data.readLongest
        if type(read_longest) == "table" then
            for _, item in ipairs(read_longest) do
                local book = item.book or {}
                local id = book.bookId or book.id
                local seconds = tonumber(item.readTime or item.readingTime)
                if id and seconds and seconds > 0 then
                    rows[#rows + 1] = {
                        source_id = self.id,
                        stable_id = tostring(id),
                        page = 0,
                        start_time = os.time() - seconds,
                        duration = seconds,
                        total_pages = 0,
                    }
                end
            end
        end
        cb(rows)
    end)
end

function Source:pullNotesAsync(identity, cb)
    if not self:configured() then
        cb(nil, _("请先扫码登录微信读书"))
        return nil
    end
    local chapter_uid = Notes.resolveChapterUid(identity)
    local cancelled, job1, job2 = false, nil, nil
    job1 = self._client:bookmarkListAsync(identity.stable_id, function(wire, err)
        if cancelled then return end
        if not wire then
            cb(nil, (type(err) == "table" and err.message) or err)
            return
        end
        local underlines = {}
        for _, row in ipairs(wire.updated or {}) do
            if type(row) == "table" then
                local uid = tostring(row.chapterUid or row.chapter_uid or "")
                if not chapter_uid or uid == tostring(chapter_uid) then
                    underlines[#underlines + 1] = row
                end
            end
        end
        if not chapter_uid or #Notes.collectRanges(underlines) == 0 then
            cb(Notes.toAnnotations(wire, chapter_uid))
            return
        end
        local ranges = Notes.collectRanges(underlines)
        local batches = Notes.reviewBatches(ranges)
        local reviews = {}
        local batch_idx = 1
        local function nextBatch()
            if cancelled then return end
            local batch = batches[batch_idx]
            batch_idx = batch_idx + 1
            if not batch then
                cb(Notes.toAnnotations(wire, chapter_uid, reviews))
                return
            end
            job2 = self._client:chapterReviewsAsync(
                identity.stable_id, chapter_uid, batch,
                function(result, rerr)
                    if cancelled then return end
                    if result and type(result.reviews) == "table" then
                        for _, review in ipairs(result.reviews) do
                            reviews[#reviews + 1] = review
                        end
                    elseif rerr then
                        logger.dbg("wechat reviews batch failed", rerr)
                    end
                    nextBatch()
                end
            )
        end
        nextBatch()
    end)
    return {
        cancel = function()
            cancelled = true
            if job1 and job1.cancel then job1:cancel() end
            if job2 and job2.cancel then job2:cancel() end
        end,
    }
end

function Source:pushNotesAsync(_identity, _annotations, cb)
    cb(nil, _("微信读书暂不支持上传划线"))
    return nil
end

--- 生命周期：书架同步、阅读时长、进度与统计。
---@param event string
---@param payload table|nil
function Source:onEvent(event, payload)
    SourceBase.onEvent(self, event, payload)
    if not self:configured() then return end
    if event == "page_changed" and type(payload) == "table" and payload.identity then
        local Progress = require("book.progress")
        local Session = require("ui.reader.session")
        local snap = Session.current()
        local pos = snap and Progress.position(snap) or {
            fraction = ProgressPosition.clampFraction(payload.percent),
            chapter_idx = payload.identity.chapter_idx,
        }
        pos.chapter_uid = payload.chapter_uid
        self._reporter:onPageChanged(payload.identity, pos)
    elseif event == "document_close" then
        self._reporter:onDocumentClose(nil, nil)
    elseif event == "stats_sync_request" then
        self:syncReadingStats(true)
    end
end

--- 用户触发的统计同步。
---@param show_message boolean
function Source:syncReadingStats(show_message)
    if self._stats_syncing then return end
    self._stats_syncing = true
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    require("ui/network/manager"):runWhenOnline(function()
        self:syncStatsAsync(nil, function(result, err)
            self._stats_syncing = false
            if show_message then
                UIManager:show(InfoMessage:new{
                    text = result and _("阅读统计已同步") or (err or _("统计同步失败")),
                    timeout = 2,
                })
            end
        end)
    end)
end

return WeChat
