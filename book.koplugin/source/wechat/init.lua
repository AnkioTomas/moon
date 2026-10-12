--[[--
微信读书数据源门面（仅异步网络）

@module koplugin.book.source.wechat
--]]

local Auth = require("source.wechat.auth")
local Client = require("source.wechat.client")
local Mapper = require("source.wechat.mapper")
local WChapter = require("source.wechat.chapter")
local Notes = require("source.wechat.notes")
local NotesPush = require("source.wechat.notes_push")
local Toc = require("source.wechat.toc")
local Reviews = require("source.wechat.reviews")
local SourceBase = require("source.base")
local Shelf = require("source.shelf")
local Progress = require("book.progress")
local Protocol = require("source.wechat.protocol")
local logger = require("utils.log")
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
        _client = Client,
        _covers = {},
    }, Source)
end

--- 缓存书籍封面 URL（仅接受 http(s)）。
---@param self WechatSource
---@param stable_id string
---@param url string
local function rememberCover(self, stable_id, url)
    if url:find("^https?://") then
        self._covers[stable_id] = url
    end
end

--- 返回微信读书源能力集。
---@return SourceCapabilities
function Source:capabilities()
    return {
        scrape = false,
        edit = false,
        stats_pull = true,
    }
end

--- 是否已登录微信读书。
---@return boolean
function Source:configured()
    return Auth.hasSession()
end

--- 阅读中时长推送间隔（秒），对齐网页端 / weread 的上报节奏。
local STATS_FLUSH_INTERVAL = 30

--- 章节开读即发「进入阅读」（putProgressAsync 就是 enter 上报）。
--- 服务端只认距本会话上次上报的真实间隔：拖到推时长时才 enter，紧跟的 rt 会被当成 0 秒。
---@param self WechatSource
---@param payload { identity: BookIdentity, position: ProgressPosition|nil }
local function enterReading(self, payload)
    if not self:configured() then return end
    self:putProgressAsync(payload.identity, payload.position, function(ok, err)
        if not ok then logger.warn("wechat enter reading failed", err) end
    end)
end

--- 开读章节时进入阅读会话，翻页时按间隔推送已落盘的阅读时长；其余事件交给基类。
---@param event string
---@param payload table|nil
function Source:onEvent(event, payload)
    if event == "chapter_changed" then
        -- enter 会写云端位置：开书拉进度期间先挂起，抢在拉取前落地会吞掉进度冲突。
        local pull = self._progress_pull
        if pull and pull.stable_id == payload.identity.stable_id then
            pull.enter = payload
        else
            enterReading(self, payload)
        end
        return
    end
    if event == "page_changed" then
        local now = os.time()
        if self:configured() and now - (self._stats_flushed_at or 0) >= STATS_FLUSH_INTERVAL then
            self._stats_flushed_at = now
            self:syncStatsAsync({ dirty_only = true }, function() end)
        end
        return
    end
    return SourceBase.onEvent(self, event, payload)
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
    local url = identity.cover_url or identity.cover or self._covers[identity.stable_id]
    if type(url) ~= "string" or url == "" then
        local stored = require("book.books_db").get(self.id, identity.stable_id)
        local cover = stored and stored.cover
        if type(cover) ~= "string" or cover == "" then
            return nil, _("无封面")
        end
        url = cover
    end
    return {
        url = url,
        headers = Auth.sessionHeaders(),
    }
end

---@param opts { dirty_only?: boolean, force?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return table
function Source:syncBooksAsync(opts, cb)
    return Shelf.syncAsync(self.id, self._client, function(wire)
        return Mapper.shelfList(wire, function(id, url) rememberCover(self, id, url) end).data
    end, opts, cb)
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
        local existing = require("book.books_db").get(self.id, b.stable_id)
        if existing then
            b.deleted = existing.deleted
        end
        local progress = require("book.progress_db").get(self.id, b.stable_id)
        if progress then
            b.percent = require("book.progress").clampPercent(progress.fraction, false, true)
        end
        require("book.store").rememberMany({ b })
        cb(b)
    end)
end

--- 旧目录没有章内 anchors，阅读会话必须重新拉取后再展示。
---@param toc BookChapter[]|nil
---@return boolean
function Source:isTocCurrent(toc)
    return Toc.isCurrent(toc)
end

--- 强制拉取目录并写回缓存；失败时调用方继续使用旧缓存。
---@param self WechatSource
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetchTocAsync(self, identity, cb)
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
        if not Toc.put(identity.source_id, identity.stable_id, chapters) then
            cb(nil, _("章节目录保存失败"))
            return
        end
        cb(chapters)
    end)
end

--- 取目录：命中本地 toc 缓存则下一个 tick 直接回调，
--- 未命中才拉章节信息并写回缓存。也是阅读会话目录恢复入口。
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:loadTocAsync(identity, cb)
    local cached = Toc.read(identity.source_id, identity.stable_id)
    if cached and #cached > 0 then
        local cancelled = false
        require("ui/uimanager"):nextTick(function()
            if not cancelled then cb(cached) end
        end)
        return { cancel = function() cancelled = true end }
    end
    return fetchTocAsync(self, identity, cb)
end

Source.refreshTocAsync = fetchTocAsync

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
    -- 查不到不能回退到当前章的 uid：会配上目标章的 ci/co 把进度报到错误章节。
    local uid = idx and Toc.uid(identity.source_id, identity.stable_id, idx)
    if uid then
        require("ui/uimanager"):nextTick(function() cb(uid) end)
        return nil
    end
    if not idx then
        require("ui/uimanager"):nextTick(function() cb(nil, _("缺少章节信息")) end)
        return nil
    end
    return self:loadTocAsync(identity, function(toc, err)
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

--- 按章打开：目录与正文都交给 source.chapter 的带 UI 流程。
---@param identity BookIdentity
---@param opts table|nil 可含 chapter_idx 指定章节
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:openBookAsync(identity, opts, cb)
    return require("source.chapter").openWithUi(self, identity, identity.book, opts, {
        loadToc = function(r, done) return self:loadTocAsync(r, done) end,
        fetchContent = fetchContent,
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

--- 缓存整本章节正文；目录只拉一次，正文按序下载并返回部分成功统计。
---@param identity BookIdentity
---@param on_progress fun(done: integer, total: integer)|nil
---@param cb fun(ok: boolean, cached: integer, err: string|nil, total: integer, failed: integer)
---@return { cancel: fun() }
function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    return require("source.chapter").cacheAllAsync(self, identity, fetchContent, on_progress, cb, nil, range)
end

--- 拉取云端进度并补齐本地需要的坐标。
--- 云端只给 chapter_uid 时回查目录换算章节序号；只给章内位置时按目录长度折算全书百分比；
--- 章节坐标写进 pos.extra 供后续 push 复用。
---@param identity BookIdentity
---@param cb fun(pos: ProgressPosition|nil, err: string|nil)
---@return { cancel: fun() }
function Source:getProgressAsync(identity, cb)
    local pull = { stable_id = identity.stable_id }
    self._progress_pull = pull
    --- 结束挂起：回调完成与取消都走这里，挂起的进入阅读只发一次。
    local function release()
        if self._progress_pull == pull then self._progress_pull = nil end
        local enter = pull.enter
        pull.enter = nil
        if enter then enterReading(self, enter) end
    end
    local reply = cb
    cb = function(pos, err)
        if self._progress_pull == pull then self._progress_pull = nil end
        reply(pos, err)
        release()
    end
    local cancelled = false
    local first, second
    first = self._client:getProgressAsync(identity.stable_id, function(wire, err)
        if cancelled then return end
        if not wire then
            cb(nil, err)
            return
        end
        local pos, chapter_uid = Mapper.progress(wire)
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
        -- wire 的 chapterIdx 是云端索引空间，本地目录过滤掉了 wordCount=0 与「封面」，
        -- 两边序号并不相等（差几章就跳到错误的章节）。只要有 uid 就一律回查目录换算成
        -- 本地 idx；没有 uid 时才不得不沿用 wire 序号。
        if not chapter_uid then
            finish()
            return
        end
        local mapped = Toc.index(identity.source_id, identity.stable_id, chapter_uid)
        if mapped then
            pos.chapter_idx = mapped
            finish()
            return
        end
        second = self:loadTocAsync(identity, function()
            if cancelled then return end
            pos.chapter_idx = Toc.index(identity.source_id, identity.stable_id, chapter_uid)
                or pos.chapter_idx
            finish()
        end)
    end)
    return { cancel = function()
            cancelled = true
            if first then first.cancel() end
            if second then second.cancel() end
            -- 拉取作废不等于不读了：挂起的进入阅读照发，否则云端位置停在旧章。
            release()
        end }
end

--- 上报阅读进度：需要 chapter_uid，优先复用 pos.extra 缓存的坐标，否则回查目录解析。
---@param identity BookIdentity
---@param pos ProgressPosition|nil 缺省视为空位置
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Source:putProgressAsync(identity, pos, cb)
    pos = pos or {}
    local frac = Progress.clampFraction(pos.fraction)
    local progress = math.max(0, math.min(100, math.floor(frac * 100 + 0.5)))
    local chapter_idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx) or 0
    local chapter_frac = pos.chapter_fraction
    local offset = chapter_frac and math.floor(Progress.clampFraction(chapter_frac) * 10000) or 0
    local summary = pos.chapter_title or ""
    local cancelled = false
    local resolve_job, push_job
    -- 只有 extra 记录的章与本次上报的章一致时才复用 uid，避免翻章后报错位置。
    local extra = pos.extra
    local chapter_uid = extra and tonumber(extra.chapter_idx) == chapter_idx
        and extra.chapter_uid or nil
    ---@param uid string 章节 uid
    local function startPush(uid)
        local source_idx = Toc.sourceIndex(identity.source_id, identity.stable_id, chapter_idx)
            or chapter_idx
        push_job = self._client:putProgressAsync(identity.stable_id, {
            progress = progress,
            chapter_uid = uid,
            chapter_idx = source_idx,
            chapter_offset = offset,
            summary = summary,
        }, function(wire, push_err)
            if wire then
                cb(true)
            else
                cb(nil, push_err)
            end
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
    return { cancel = function()
            cancelled = true
            if resolve_job and resolve_job.cancel then resolve_job.cancel() end
            if push_job and push_job.cancel then push_job.cancel() end
        end }
end

--- 补报阅读时长：对每章补齐 reader 状态后发 web/book/read。
---
--- 这是微信侧时长的**唯一**来源。本地行带 chapter_idx/chapter_fraction（book.stats
--- 采集时落库），阅读中按 STATS_FLUSH_INTERVAL 节流、关书时各经 syncStatsAsync 推送
--- 同一批待同步行；不要另开一路心跳，否则同一段时间会被计两遍。
---
--- 对齐网页端：rt 是距上次上报的秒数，所以要在阅读中持续小批推送；每条都带真实位置
--- （这个接口同时更新云端进度，填 0 会把进度打回开头），最近读的章最后报。
---@param rows table[]|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:pushStatsAsync(rows, cb)
    if self.cfg.sync_reading_time == false then
        -- 关闭同步时直接确认本地行：不留积压，重新开启后不会把关闭期间的时长补报上去。
        local ids = {}
        for _idx, row in ipairs(rows or {}) do ids[#ids + 1] = row.id end
        cb({ ok = true, synced_ids = ids })
        return nil
    end
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
    for _idx, row in ipairs(rows or {}) do
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
                    duration = 0, chapter_fraction = 0, last_at = 0, ids = {} }
                buckets[key] = bucket
            end
            bucket.ids[#bucket.ids + 1] = row.id
            bucket.duration = bucket.duration + (tonumber(row.duration) or 0)
            -- 位置取该章最后一段的章内进度，而不是最大值：回翻重读时要报读者真实所在处。
            local at = tonumber(row.start_time) or 0
            if at >= bucket.last_at then
                bucket.last_at = at
                bucket.chapter_fraction = tonumber(row.chapter_fraction) or bucket.chapter_fraction
            end
        end
    end
    if skipped > 0 then
        logger.warn("wechat stats push skipped rows without chapter_idx", skipped)
    end

    local work = {}
    for _bucket_key, bucket in pairs(buckets) do
        work[#work + 1] = bucket
    end
    table.sort(work, function(a, b)
        if a.last_at ~= b.last_at then
            return a.last_at < b.last_at
        end
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
    --- reader 会话首次上报前先发一次进入阅读（与网页端 / weread 一致，否则时长不计）。
    ---@param bucket table 形如 { stable_id, chapter_idx, duration, chapter_fraction, last_at, ids }
    ---@param chapter_uid string 章节 uid
    local function report(bucket, chapter_uid)
        local reader = require("source.wechat.context").reader(bucket.stable_id, chapter_uid)
        local toc = Toc.read(self.id, bucket.stable_id)
        local chapter = toc and toc[bucket.chapter_idx]
        local whole = Toc.wholeFraction(self.id, bucket.stable_id, bucket.chapter_idx, bucket.chapter_fraction)
        local position = {
            book_id = bucket.stable_id,
            chapter_uid = chapter_uid,
            chapter_idx = Toc.sourceIndex(self.id, bucket.stable_id, bucket.chapter_idx)
                or bucket.chapter_idx,
            chapter_offset = math.floor(Progress.clampFraction(bucket.chapter_fraction) * 10000),
            summary = chapter and chapter.title or "",
            progress = math.floor((whole or 0) * 100 + 0.5),
            psvts = reader.psvts,
            pclts = reader.pclts,
        }
        local referer = Protocol.readerUrl(bucket.stable_id, chapter_uid)
        local function sendTime()
            position.elapsed_seconds = bucket.duration
            job = self._client:reportReadAsync(Protocol.makeReadPayload(position), referer, function(data, rerr)
                if cancelled then return end
                if not data then
                    fail(rerr or _("阅读时长上报失败"))
                    return
                end
                for _idx, id in ipairs(bucket.ids) do
                    confirmed[#confirmed + 1] = id
                end
                nextItem()
            end)
        end
        if reader.entered then
            sendTime()
            return
        end
        job = self._client:reportReadAsync(Protocol.makeEnterReadPayload(position), referer, function(data, rerr)
            if cancelled then return end
            if not data then
                fail(rerr or _("阅读时长上报失败"))
                return
            end
            reader.entered = true
            sendTime()
        end)
    end

    --- 把桶的章节序号解析成 uid 后上报；缓存没有就拉一次目录，仍解析不出视为失败。
    ---@param bucket table 章节聚合桶
    local function resolveAndReport(bucket)
        local chapter_uid = Toc.uid(self.id, bucket.stable_id, bucket.chapter_idx)
        if chapter_uid then
            report(bucket, chapter_uid)
            return
        end
        job = self:loadTocAsync({ source_id = self.id, stable_id = bucket.stable_id }, function()
            if cancelled then return end
            chapter_uid = Toc.uid(self.id, bucket.stable_id, bucket.chapter_idx)
            if not chapter_uid then
                fail(_("缺少章节信息"))
                return
            end
            report(bucket, chapter_uid)
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
    return { cancel = function()
            cancelled = true
            if job and job.cancel then job:cancel() end
        end }
end

--- 每次统计同步最多补拉 readinfo 的书数；首次同步整个书架分几轮补齐。
local READINFO_BATCH = 20

--- 拉取累计总量，再按年定位月份、按月拉取真实日明细；
--- 最后对书架里云端累计有变化的书逐本拉 readinfo 按日明细。
---@param cb fun(result: BookStatsRow[]|BookStatsPullResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:pullStatsAsync(cb)
    local cancelled, jobs = false, {}
    local function track(job)
        jobs[#jobs + 1] = job
    end
    local function request(mode, base_time, done)
        track(self._client:readStatsAsync(mode, base_time, done))
    end
    --- 单书明细是尽力而为：书架或某本书失败只跳过，不连累账户级统计；
    --- 没拉到的书快照不变，下次同步仍判为有变化而重试。
    local function collectBooks(done)
        track(self._client:shelfSyncAsync(function(shelf, err)
            if cancelled then return end
            if not shelf then
                logger.warn("wechat book stats shelf failed", err)
                done({})
                return
            end
            local pending = require("source.wechat.stats").changedBooks(
                shelf.bookProgress, require("book.stats_db").bookTotals(self.id), READINFO_BATCH
            )
            local results, index = {}, 1
            local function nextBook()
                if cancelled then return end
                local book = pending[index]
                index = index + 1
                if not book then
                    done(results)
                    return
                end
                track(self._client:readInfoAsync(book.id, function(wire, rerr)
                    if cancelled then return end
                    if wire then
                        book.wire = wire
                        results[#results + 1] = book
                    else
                        logger.warn("wechat readinfo failed", book.id, rerr)
                    end
                    nextBook()
                end))
            end
            nextBook()
        end))
    end
    local function collect(mode, bases, done)
        local results, index = {}, 1
        local function nextPeriod()
            if cancelled then return end
            local base_time = bases[index]
            index = index + 1
            if not base_time then
                done(results)
                return
            end
            request(mode, base_time, function(wire, err)
                if cancelled then return end
                if not wire then
                    cb(nil, err)
                    return
                end
                results[#results + 1] = wire
                nextPeriod()
            end)
        end
        nextPeriod()
    end
    request("overall", nil, function(overall, err)
        if cancelled then return end
        if not overall then
            cb(nil, err)
            return
        end
        local StatsMapper = require("source.wechat.stats")
        collect("annually", StatsMapper.annualBaseTimes(overall), function(annuals)
            local monthly_bases = {}
            for _idx, annual in ipairs(annuals) do
                for _idx, base_time in ipairs(StatsMapper.monthlyBaseTimes(annual)) do
                    monthly_bases[#monthly_bases + 1] = base_time
                end
            end
            collect("monthly", monthly_bases, function(monthlies)
                collectBooks(function(book_details)
                    cb(StatsMapper.fromWires(
                        self.id, overall, annuals, monthlies, book_details, os.time()
                    ))
                end)
            end)
        end)
    end)
    return { cancel = function()
            cancelled = true
            for _idx, job in ipairs(jobs) do job:cancel() end
        end }
end

--- 解析本章 chapter_uid 后再发请求；取消同时覆盖两段。
---@param self WechatSource
---@param identity BookIdentity
---@param cb fun(data: any, err: string|nil)
---@param start fun(chapter_uid: string, cb: fun(data: any, err: string|nil)): { cancel: fun() }|nil
---@return { cancel: fun() }
local function withChapterUid(self, identity, cb, start)
    local job
    local cancelled = false
    job = resolveChapterUidAsync(self, identity, nil, function(chapter_uid, err)
        if cancelled then return end
        if not chapter_uid then
            cb(nil, err)
            return
        end
        job = start(chapter_uid, cb)
    end)
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

--- 拉取某本书的划线与想法，合并成 KOReader 注解数组。
--- 想法接口失败只记日志不算错：划线本身已经可用。
---@param identity BookIdentity
---@param cb fun(annotations: table[]|nil, err: string|nil, meta: table|nil)
---@return { cancel: fun() }|nil
function Source:pullNotesAsync(identity, cb)
    if not self:configured() then
        cb(nil, _("请先扫码登录微信读书"))
        return nil
    end
    local cancelled = false
    local job
    -- 章节号按 uid 查本地目录，缓存过期时查不到：先确保目录在。目录拉不到照样拉笔记，章节号留空。
    local toc_job = self:loadTocAsync(identity, function()
        if cancelled then return end
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
                local annotations = Notes.toAnnotations(
                    wire, nil, reviews, identity.source_id, identity.stable_id
                )
                cb(annotations, nil, { authoritative = Notes.reviewsComplete(reviews) })
            end)
        end)
    end)
    return { cancel = function()
            cancelled = true
            if toc_job then toc_job.cancel() end
            if job then job.cancel() end
        end }
end

--- 开章后把通用注解转为 KOReader 可读坐标。
---@param document table|nil
---@param annotations table[]
---@param html_path string|nil
---@param current table[]|nil
---@return table[]
function Source:localizeAnnotations(document, annotations, html_path, current)
    return Notes.localizeAnnotations(document, annotations, html_path, current)
end

function Source:cleanAnnotations(items, total_pages)
    return Notes.cleanAnnotations(items, total_pages)
end

function Source:prepareLocalAnnotations(previous, current)
    return Notes.prepareLocalAnnotations(previous, current)
end

function Source:mergeAnnotations(remote, current, paging, authoritative)
    return Notes.mergeAnnotations(remote, current, paging, authoritative)
end

--- 上传当前章的划线与想法。
--- 微信读书的划线坐标依赖章节 HTML，因此只能按章推送：identity 必须带 chapter_idx，
--- 且该章正文已落盘（缺 HTML 时无法定位划线区间）。无可推送内容直接回调成功。
---@param identity BookIdentity
---@param annotations table[] KOReader 注解数组，就地改写
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:pushNotesAsync(identity, annotations, cb)
    if not self:configured() then
        cb(nil, _("请先扫码登录微信读书"))
        return nil
    end
    if not Notes.preparePush(annotations) then
        cb(true)
        return nil
    end
    local chapter_idx = tonumber(identity.chapter_idx)
    if not chapter_idx then
        cb(nil, _("按章书籍请打开章节后同步划线"))
        return nil
    end
    local local_html
    local f = io.open(require("utils.paths").chapterPath(identity.stable_id, chapter_idx, identity.source_id), "rb")
    if f then
        local_html = f:read("*a")
        f:close()
    end
    return withChapterUid(self, identity, cb, function(chapter_uid, done)
        return NotesPush.run(self._client, identity, chapter_uid, local_html, annotations, done)
    end)
end

--- 阅读页是否显示他人段评（设置页开关，默认关）。
---@return boolean
function Source:paragraphReviewsEnabled()
    return require("utils.settings").getSource(self.id).show_paragraph_reviews == true
end

--- 本章段评热点，已定位到本地章节 xpointer。
---@param identity BookIdentity 章会话身份
---@param html_path string 本地章节文件（即当前文档）
---@param cb fun(spots: WechatReviewSpot[]|nil, err: string|nil)
---@return { cancel: fun() }
function Source:paragraphReviewsAsync(identity, html_path, cb)
    local f = assert(io.open(html_path, "rb"))
    local html = f:read("*a")
    f:close()
    return withChapterUid(self, identity, cb, function(chapter_uid, done)
        return Reviews.spotsAsync(self._client, identity.stable_id, chapter_uid, html, done)
    end)
end

--- 某句的一页段评。
---@param identity BookIdentity
---@param range string 热点的 range
---@param max_idx integer 首页 0，之后用上一页回传的 max_idx
---@param cb fun(page: WechatReviewPage|nil, err: string|nil)
---@return { cancel: fun() }
function Source:paragraphReviewPageAsync(identity, range, max_idx, cb)
    return withChapterUid(self, identity, cb, function(chapter_uid, done)
        return Reviews.pageAsync(self._client, identity.stable_id, chapter_uid, range, max_idx, done)
    end)
end

return WeChat
