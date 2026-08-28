--[[--
微信读书数据源门面（仅异步网络）

@module koplugin.book.source.wechat
--]]

local Auth = require("source.wechat.auth")
local Client = require("source.wechat.client")
local Mapper = require("source.wechat.mapper")
local WChapter = require("source.wechat.chapter")
local Notes = require("source.wechat.notes")
local Toc = require("source.wechat.toc")
local SourceBase = require("source.base")
local ProgressPosition = require("types.book_progress")
local JSON = require("json")
local Protocol = require("source.wechat.protocol")
local logger = require("logger")
local _ = require("gettext")

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
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

--- 构造微信读书源实例。
---@return WechatSource
function WeChat.new()
    local cfg = require("utils.settings").getSource("wechat")
    local meta = WeChat.meta()
    ---@type WechatSource
    return setmetatable({
        id = meta.id,
        name = meta.name,
        type = meta.type,
        cfg = cfg,
        _client = Client:new(cfg),
        _covers = {},
    }, Source)
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
                chapter_idx = row.chapter_idx,
                chapter_fraction = row.chapter_fraction,
                extra = (row.chapter_uid and row.chapter_idx)
                    and { chapter_uid = row.chapter_uid, chapter_idx = row.chapter_idx } or nil,
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
        stats_pull = true,
        store = true,
    }
end

--- 是否已登录微信读书。
---@return boolean
function Source:configured()
    return Auth.hasSession()
end

--- 清空封面 URL、阅读上下文与目录缓存。
function Source:clearCaches()
    self._covers = {}
    require("source.wechat.context").clear()
    Toc.clear()
end

--- 关闭这个实例。只清实例自己的封面表：Context（psvts）与 Toc 是进程级的，
--- 换源时关旧实例若把它们一起清了，正在阅读那本书的上报会报「请先打开该章节」。
function Source:close()
    self._covers = {}
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
        headers = Auth.sessionHeaders(),
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
            cb(nil, err)
        end
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job:cancel() end
    end }
end

--- 书城列表：无关键词走分类榜单，有关键词走搜索。
--- 两条路径的 wire 都按搜索结果格式映射，并顺手记下封面 URL 供后续取图。
---@param opts BookListOpts|nil
---@param cb fun(data: BookListResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:listStoreAsync(opts, cb)
    opts = opts or {}
    local search = opts.search or ""
    --- 把书城 wire 映射成书籍列表；失败原样透传错误。
    ---@param wire table|nil
    ---@param err string|nil
    local on_wire = function(wire, err)
        if wire then
            cb(Mapper.searchList(wire, function(id, url)
                rememberCover(self, id, url)
            end))
        else
            cb(nil, err)
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
                cb(nil, sync_err)
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

--- 拉取书籍详情并缓存封面 URL；映射不出书籍时按「详情为空」失败。
---@param identity BookIdentity
---@param cb fun(book: Book|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:getDetailAsync(identity, cb)
    return self._client:bookInfoAsync(identity.stable_id, function(wire, err)
        if not wire then
            cb(nil, err)
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

--- 取目录：命中本地 toc 缓存则下一个 tick 直接回调（返回 nil，无可取消 job），
--- 未命中才拉章节信息并写回缓存。
---@param self WechatSource
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function getTocAsync(self, identity, cb)
    local cached = Toc.read(identity.source_id, identity.stable_id)
    if cached and #cached > 0 then
        require("ui/uimanager"):nextTick(function() cb(cached) end)
        return
    end
    return self._client:chapterInfosAsync(identity.stable_id, function(wire, err)
        if not wire then
            cb(nil, err)
            return
        end
        local chapters = Mapper.chapters(wire, identity.stable_id)
        if not chapters then
            cb(nil, _("章节列表为空"))
            return
        end
        Toc.put(identity.source_id, identity.stable_id, chapters)
        cb(chapters)
    end)
end

--- 目录缓存缺失时先拉 toc，再解析 chapter_uid。
---@param self WechatSource
---@param identity BookIdentity
---@param chapter_idx integer|nil
---@param cb fun(uid: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function resolveChapterUidAsync(self, identity, chapter_idx, cb)
    -- chapter_idx 从 1 起；0 是「整本文件」哨兵，在 Lua 里为真值，必须归一成 nil，
    -- 否则会拿 idx=0 去拉一份注定查不到的目录。
    local idx = tonumber(chapter_idx) or tonumber(identity.chapter_idx)
    if idx and idx < 1 then
        idx = nil
    end
    local uid = (idx and Toc.uid(identity.source_id, identity.stable_id, idx))
        or (identity.chapter_idx
            and Toc.uid(identity.source_id, identity.stable_id, identity.chapter_idx))
    if uid then
        require("ui/uimanager"):nextTick(function() cb(uid) end)
        return nil
    end
    if not idx then
        require("ui/uimanager"):nextTick(function() cb(nil, _("缺少章节信息")) end)
        return nil
    end
    return getTocAsync(self, identity, function(toc, err)
        if not toc then
            cb(nil, err or _("缺少章节信息"))
            return
        end
        uid = Toc.uid(identity.source_id, identity.stable_id, idx)
        if uid then
            cb(uid)
        else
            cb(nil, _("缺少章节信息"))
        end
    end)
end

---@param r BookIdentity
---@param chapter BookChapter
---@param done fun(payload: ChapterContentPayload|nil, err: any)
local function fetchContent(r, chapter, done)
    return WChapter.fetchContentAsync(r.stable_id, chapter, done)
end

--- 按章打开：目录、正文与缓存刷新都交给 source.chapter 的带 UI 流程。
---@param identity BookIdentity
---@param opts table|nil 可含 chapter_idx 指定章节
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:openBookAsync(identity, opts, cb)
    return require("source.chapter").openWithUi(self, identity, identity.book, opts, {
        loadToc = function(r, done) return getTocAsync(self, r, done) end,
        fetchContent = fetchContent,
        refreshCached = function(_r, chapter, path, done)
            return WChapter.refreshCached(path, done)
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
        fetchContent = fetchContent,
    }, cb)
end

--- 拉取云端进度并补齐本地需要的坐标。
--- 云端只给 chapter_uid 时回查目录换算章节序号；只给章内位置时按目录长度折算全书百分比；
--- 章节坐标写进 pos.extra 供后续 push 复用。
---@param identity BookIdentity
---@param cb fun(pos: ProgressPosition|nil, err: string|nil)
---@return { cancel: fun() }
function Source:getProgressAsync(identity, cb)
    local cancelled = false
    local first, second
    first = self._client:getProgressAsync(identity.stable_id, function(wire, err)
        if cancelled then return end
        if not wire then
            cb(nil, err)
            return
        end
        local pos, chapter_uid = Mapper.progress(wire)
        if not pos then
            cb(nil, _("进度为空"))
            return
        end
        -- 云端只给了章节位置时，按目录长度折算成全书 fraction。
        local function finish()
            if pos.chapter_idx and (pos.fraction == nil or pos.fraction == 0) then
                pos.fraction = Toc.wholeFraction(
                    identity.source_id, identity.stable_id, pos.chapter_idx, pos.chapter_fraction
                ) or pos.fraction
            end
            -- 章节坐标随进度一起存本地：目录缓存过期后 push 可直接复用，免一轮请求。
            -- 必须带上 chapter_idx，否则读者翻章后会拿旧 uid 把进度报到错误章节。
            if chapter_uid and pos.chapter_idx then
                pos.extra = { chapter_uid = chapter_uid, chapter_idx = pos.chapter_idx }
            end
            cb(pos)
        end
        if not chapter_uid or pos.chapter_idx then
            finish()
            return
        end
        second = getTocAsync(self, identity, function()
            if cancelled then return end
            pos.chapter_idx = Toc.index(identity.source_id, identity.stable_id, chapter_uid)
            finish()
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

--- 上报阅读进度：需要 chapter_uid，优先复用 pos.extra 缓存的坐标，否则回查目录解析。
---@param identity BookIdentity
---@param pos ProgressPosition|nil 缺省视为空位置
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Source:putProgressAsync(identity, pos, cb)
    pos = pos or {}
    local frac = ProgressPosition.clampFraction(pos.fraction)
    local progress = math.max(0, math.min(100, math.floor(frac * 100 + 0.5)))
    local chapter_idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx) or 0
    local chapter_frac = pos.chapter_fraction
    local offset = chapter_frac and math.floor(ProgressPosition.clampFraction(chapter_frac) * 10000) or 0
    local summary = pos.chapter_title or ""
    local cancelled = false
    local resolve_job, ensure_job, push_job
    -- 只有 extra 记录的章与本次上报的章一致时才复用 uid，避免翻章后报错位置。
    local extra = pos.extra
    local chapter_uid = extra and tonumber(extra.chapter_idx) == chapter_idx
        and extra.chapter_uid or nil
    --- 拿到章节 uid 后先补齐 psvts 签名参数，再上报进度。
    ---@param uid string 章节 uid
    local function startPush(uid)
        ensure_job = WChapter.ensurePsvtsAsync(identity.stable_id, uid, function(ok, err)
            if cancelled then return end
            if not ok then
                cb(nil, err)
                return
            end
            push_job = self._client:putProgressAsync(identity.stable_id, {
                progress = progress,
                chapter_uid = uid,
                chapter_idx = chapter_idx,
                chapter_offset = offset,
                summary = summary,
            }, function(wire, push_err)
                if wire then
                    cb(true)
                else
                    cb(nil, push_err)
                end
            end)
        end)
    end
    if chapter_uid then
        startPush(chapter_uid)
    else
        resolve_job = resolveChapterUidAsync(self, identity, chapter_idx, function(uid, err)
            if cancelled then return end
            if not uid then
                cb(nil, err or _("缺少章节信息"))
                return
            end
            startPush(uid)
        end)
    end
    return {
        cancel = function()
            cancelled = true
            if resolve_job and resolve_job.cancel then resolve_job.cancel() end
            if ensure_job and ensure_job.cancel then ensure_job.cancel() end
            if push_job and push_job.cancel then push_job.cancel() end
        end,
    }
end

--- 补报阅读时长：对每章现拉 psvts 后发 web/book/read。
---
--- 这是微信侧时长的**唯一**来源。本地行带 chapter_idx/chapter_fraction（book.stats
--- 采集时落库），关书时经 syncStatsAsync 触发。翻页时不要再另开一路心跳上报，
--- 否则同一段时间会被计两遍。
---@param rows table[]|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:pushStatsAsync(rows, cb)
    if not self:configured() then
        cb(nil, _("请先扫码登录微信读书"))
        return nil
    end

    -- 同一章可能有多条分页记录，按 (stable_id, chapter_idx) 聚合时长与最大章内进度。
    -- 每个桶记住自己的行 id：逐章上报中途失败时只确认已报出去的章，
    -- 未报的行保持待上传，避免下次重试把同一段时间再报一遍。
    local buckets = {}
    local confirmed = {}
    local skipped = 0
    for _, row in ipairs(rows or {}) do
        local stable_id = row.stable_id
        local chapter_idx = tonumber(row.chapter_idx)
        if type(stable_id) ~= "string" or stable_id == "" or not chapter_idx then
            -- 微信按章上报，没有章节坐标就无处可报；直接确认，不留在队列里反复重试。
            skipped = skipped + 1
            confirmed[#confirmed + 1] = row.id
        else
            local key = stable_id .. "\31" .. tostring(chapter_idx)
            local bucket = buckets[key]
            if not bucket then
                bucket = { stable_id = stable_id, chapter_idx = chapter_idx,
                    duration = 0, chapter_fraction = 0, ids = {} }
                buckets[key] = bucket
            end
            bucket.ids[#bucket.ids + 1] = row.id
            bucket.duration = bucket.duration + (tonumber(row.duration) or 0)
            local frac = tonumber(row.chapter_fraction)
            if frac and frac > bucket.chapter_fraction then
                bucket.chapter_fraction = frac
            end
        end
    end
    if skipped > 0 then
        logger.warn("wechat stats push skipped rows without chapter_idx", skipped)
    end

    local work = {}
    for _, bucket in pairs(buckets) do
        work[#work + 1] = bucket
    end
    table.sort(work, function(a, b)
        if a.stable_id ~= b.stable_id then
            return a.stable_id < b.stable_id
        end
        return a.chapter_idx < b.chapter_idx
    end)

    if #work == 0 then
        cb({ ok = true, synced_ids = confirmed })
        return nil
    end

    local cancelled = false
    local job
    local index = 1
    local nextItem

    --- 中途失败：已报出去的章照常确认，剩下的留待下次重试。
    ---@param err string|nil
    local function fail(err)
        if #confirmed == 0 then
            cb(nil, err)
            return
        end
        logger.warn("wechat stats push partial", err, #confirmed)
        cb({ ok = true, synced_ids = confirmed })
    end

    --- 上报一个章节桶的阅读时长；成功则确认桶内全部行 id 并处理下一个。
    ---@param bucket table 形如 { stable_id, chapter_idx, duration, chapter_fraction, ids }
    ---@param chapter_uid string 章节 uid
    local function report(bucket, chapter_uid)
        local psvts = require("source.wechat.context").psvts(bucket.stable_id, chapter_uid)
        local payload = Protocol.makeReadPayload({
            book_id = bucket.stable_id,
            chapter_uid = chapter_uid,
            chapter_idx = bucket.chapter_idx,
            chapter_offset = math.floor(ProgressPosition.clampFraction(bucket.chapter_fraction) * 10000),
            summary = "",
            progress = 0,
            psvts = psvts or "",
            elapsed_seconds = bucket.duration,
        })
        job = self._client:reportReadAsync(JSON.encode(payload), Protocol.readerUrl(bucket.stable_id, chapter_uid), function(data, rerr)
            if cancelled then return end
            if not data then
                fail(rerr or _("阅读时长上报失败"))
                return
            end
            for _, id in ipairs(bucket.ids) do
                confirmed[#confirmed + 1] = id
            end
            nextItem()
        end)
    end

    --- 先补齐该章的 psvts 签名参数，再上报时长；补不上视为本轮失败。
    ---@param bucket table 章节聚合桶
    ---@param chapter_uid string 章节 uid
    local function ensureAndReport(bucket, chapter_uid)
        job = WChapter.ensurePsvtsAsync(bucket.stable_id, chapter_uid, function(ok, err)
            if cancelled then return end
            if not ok then
                fail(err or _("无法打开章节"))
                return
            end
            report(bucket, chapter_uid)
        end)
    end

    --- 把桶的章节序号解析成 uid 后上报；缓存没有就拉一次目录，仍解析不出视为失败。
    ---@param bucket table 章节聚合桶
    local function resolveAndReport(bucket)
        local chapter_uid = Toc.uid(self.id, bucket.stable_id, bucket.chapter_idx)
        if chapter_uid then
            ensureAndReport(bucket, chapter_uid)
            return
        end
        job = getTocAsync(self, { source_id = self.id, stable_id = bucket.stable_id }, function()
            if cancelled then return end
            chapter_uid = Toc.uid(self.id, bucket.stable_id, bucket.chapter_idx)
            if not chapter_uid then
                fail(_("缺少章节信息"))
                return
            end
            ensureAndReport(bucket, chapter_uid)
        end)
    end

    nextItem = function()
        if cancelled then return end
        local bucket = work[index]
        index = index + 1
        if not bucket then
            cb({ ok = true, synced_ids = confirmed })
            return
        end
        resolveAndReport(bucket)
    end

    nextItem()
    return {
        cancel = function()
            cancelled = true
            if job and job.cancel then job:cancel() end
        end,
    }
end

--- 拉取月度阅读统计并映射成 reading_stats 领域记录。
---@param cb fun(result: BookStatsRow[]|BookStatsPullResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:pullStatsAsync(cb)
    return self._client:readStatsAsync("monthly", nil, function(wire, err)
        if not wire then
            cb(nil, err)
            return
        end
        cb(require("source.wechat.stats").fromWire(self.id, wire))
    end)
end

--- 拉取某本书的划线与想法，合并成 KOReader 注解数组。
--- 想法接口失败只记日志不算错：划线本身已经可用。
---@param identity BookIdentity
---@param cb fun(annotations: table[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:pullNotesAsync(identity, cb)
    if not self:configured() then
        cb(nil, _("请先扫码登录微信读书"))
        return nil
    end
    local cancelled = false
    local job
    job = self._client:bookmarkListAsync(identity.stable_id, function(wire, err)
        if cancelled then return end
        if not wire then
            cb(nil, err)
            return
        end
        -- 想法拉不到不算失败：划线本身已经可用。
        job = self._client:myReviewsAsync(identity.stable_id, function(reviews, rerr)
            if cancelled then return end
            if not reviews then
                logger.warn("wechat my reviews failed", identity.stable_id, rerr)
            end
            cb(Notes.toAnnotations(
                wire, nil, reviews, identity.source_id, identity.stable_id
            ))
        end)
    end)
    return {
        cancel = function()
            cancelled = true
            if job and job.cancel then job.cancel() end
        end,
    }
end

--- 开章后把通用注解转为 KOReader 可读坐标。
---@param document table|nil
---@param annotations table[]
---@param html_path string|nil
---@return table[]
function Source:localizeAnnotations(document, annotations, html_path)
    return Notes.localizeAnnotations(document, annotations, html_path)
end

--- 上传当前章的划线与想法。
--- 微信读书的划线坐标依赖章节 HTML，因此只能按章推送：identity 必须带 chapter_idx，
--- 且该章正文已落盘（缺 HTML 时无法定位划线区间）。无可推送内容直接回调成功。
---@param identity BookIdentity
---@param annotations table[] KOReader 注解数组
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:pushNotesAsync(identity, annotations, cb)
    if not self:configured() then
        cb(nil, _("请先扫码登录微信读书"))
        return nil
    end
    if type(identity) ~= "table" or type(identity.stable_id) ~= "string" or identity.stable_id == "" then
        cb(nil, _("无效书籍"))
        return nil
    end
    local candidates = Notes.pushCandidates(annotations)
    if #candidates == 0 and #Notes.notePushCandidates(annotations) == 0 then
        cb(true)
        return nil
    end
    local chapter_idx = tonumber(identity.chapter_idx)
    if not chapter_idx then
        cb(nil, _("按章书籍请打开章节后同步划线"))
        return nil
    end
    local cancelled, current_job, resolve_job = false, nil, nil
    local html
    local path = require("utils.paths").chapterPath(identity.stable_id, chapter_idx, identity.source_id)
    local f = io.open(path, "rb")
    if f then
        html = f:read("*a")
        f:close()
    end
    local book_id = identity.stable_id
    local Context = require("source.wechat.context")

    --- 收尾回调；已取消则丢弃结果。
    ---@param ok boolean|nil
    ---@param err string|nil
    local function finish(ok, err)
        if not cancelled then cb(ok, err) end
    end

    --- 串行推送本章的划线，走完再推想法。
    ---@param chapter_uid string 章节 uid
    ---@param book_version number|nil 书籍版本号，划线坐标需要它对齐
    local function pushAll(chapter_uid, book_version)
        -- 前向声明：划线队列走完后转入想法推送，必须先于 nextBookmark 进入作用域。
        local pushReviews
        local index = 1
        --- 推送队列中的下一条划线；队列走完转入想法推送。
        local function nextBookmark()
            if cancelled then return end
            local item = candidates[index]
            index = index + 1
            if not item then
                pushReviews(chapter_uid)
                return
            end
            local body, body_err = Notes.toBookmarkBody(
                book_id, chapter_uid, chapter_idx, book_version, item, html
            )
            if not body then
                finish(nil, body_err)
                return
            end
            current_job = self._client:addBookmarkAsync(book_id, chapter_uid, body, function(wire, err)
                current_job = nil
                if cancelled then return end
                if not wire then
                    finish(nil, err or _("划线上传失败"))
                    return
                end
                local bookmark_id = wire.bookmarkId or wire.id
                if bookmark_id then
                    item.wr_bookmark_id = bookmark_id
                    item.wr_range = body.range
                end
                nextBookmark()
            end)
        end

        local review_items, review_index = nil, 1
        pushReviews = function(_chapter_uid)
            if cancelled then return end
            -- 惰性取一次：此时划线已全部上传并回写 wr_bookmark_id，新划线的想法才够格入选。
            review_items = review_items or Notes.notePushCandidates(annotations)
            local item = review_items[review_index]
            review_index = review_index + 1
            if not item then
                finish(true)
                return
            end
            local body, body_err
            if item.wr_review_id then
                body, body_err = Notes.toReviewEditBody(item)
                if not body then
                    finish(nil, body_err)
                    return
                end
                current_job = self._client:editReviewAsync(body, function(wire, err)
                    current_job = nil
                    if cancelled then return end
                    if not wire then
                        finish(nil, err or _("想法上传失败"))
                        return
                    end
                    pushReviews(_chapter_uid)
                end)
                return
            end
            body, body_err = Notes.toReviewBody(book_id, _chapter_uid, item)
            if not body then
                finish(nil, body_err)
                return
            end
            current_job = self._client:addReviewAsync(body, function(wire, err)
                current_job = nil
                if cancelled then return end
                if not wire then
                    finish(nil, err or _("想法上传失败"))
                    return
                end
                local review_id = wire.reviewId
                    or (type(wire.data) == "table" and wire.data.reviewId)
                if review_id then
                    item.wr_review_id = review_id
                end
                pushReviews(_chapter_uid)
            end)
        end

        nextBookmark()
    end

    --- 确保拿到书籍版本号后再推送：优先用上下文缓存，缺失才拉一次书籍详情并记住。
    ---@param chapter_uid string 章节 uid
    local function withBookVersion(chapter_uid)
        local book_version = Context.bookVersion(book_id)
        if book_version then
            pushAll(chapter_uid, book_version)
            return
        end
        current_job = self._client:bookInfoAsync(book_id, function(wire, err)
            current_job = nil
            if cancelled then return end
            if not wire then
                finish(nil, err)
                return
            end
            book_version = Mapper.bookVersion(wire)
            if not book_version then
                finish(nil, _("缺少书籍版本"))
                return
            end
            Context.rememberBookVersion(book_id, book_version)
            pushAll(chapter_uid, book_version)
        end)
    end

    resolve_job = resolveChapterUidAsync(self, identity, chapter_idx, function(chapter_uid, err)
        if cancelled then return end
        if not chapter_uid then
            finish(nil, err or _("缺少章节信息"))
            return
        end
        withBookVersion(chapter_uid)
    end)
    return {
        cancel = function()
            cancelled = true
            if resolve_job and resolve_job.cancel then resolve_job.cancel() end
            if current_job and current_job.cancel then current_job:cancel() end
        end,
    }
end

--- 生命周期：用户触发的统计同步。
---
--- 阅读时长不在此处心跳上报：本地 ``book.stats`` 采集是唯一来源，关书时经
--- ``syncStatsAsync`` → ``pushStatsAsync`` 按章补报。翻页时再报一次会让微信侧时长翻倍。
---@param event string
---@param payload table|nil
function Source:onEvent(event, payload)
    SourceBase.onEvent(self, event, payload)
    if not self:configured() then return end
    if event == "stats_sync_request" then
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
