--[[--
微信读书数据源门面（仅异步网络）

两套会话别混：eink.lua 扫码拿 accessToken / refreshToken（设置页走这条），auth.lua 网页 cookie（正文、笔记、部分统计）。
开章发「进入阅读」须早于时长上报；开书拉进度期间先挂起，免得抢在冲突选择前写云端位置。
时长走 30 秒心跳（开章 / 翻页 / 唤醒起，关书 / 休眠停），离线跳拍不补报。划线经 notes.lua / annotations.lua 与网页 range 互定位。

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
local ReviewCache = require("book.review_cache")
local Browse = require("source.browse")
local SourceBase = require("source.base")
local Shelf = require("source.shelf")
local Progress = require("book.progress")
local App = require("source.wechat.app")
local Eink = require("source.wechat.eink")
local logger = require("utils.log")
local Text = require("utils.text")
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
        edit = true,
        stats_pull = true,
    }
end

--- 是否已登录微信读书。
---@return boolean
function Source:configured()
    return Auth.hasSession()
end

--- 章节开读即发「进入阅读」（putProgressAsync 就是 enter 上报）。
---@param self WechatSource
---@param payload { identity: BookIdentity, position: ProgressPosition|nil }
local function enterReading(self, payload)
    if not self:configured() then return end
    self:putProgressAsync(payload.identity, payload.position, function(ok, err)
        if not ok then logger.warn("wechat enter reading failed", err) end
    end)
end

--- 开读章节时进入阅读会话；其余事件交给基类。阅读时长不实时报：本地采集的统计行经 pushStatsAsync 按 App 协议上报，开章（上一章已落库）、关书、唤醒、联网时推。
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
        -- 上一章的时长这时已落库：有网就顺手补报（Stats.push 自带在飞去重，没网留作脏行）。
        if self:configured() and require("ui/network/manager"):isConnected() then
            require("book.stats").push(self)
        end
        return
    end
    if event == "book_meta_changed" and self:configured() then
        self:pushCategoryAsync(payload.identity.stable_id)
        return
    end
    return SourceBase.onEvent(self, event, payload)
end

--- 把本地分类上行成书架分组：同名分组加入，没有就新建；分类清空则退出所有分组。
--- 新书不带分组，只有用户改分类才会走到这里。失败只记日志，分类留在本地。
---@param stable_id string
---@return { cancel: fun() }|nil
function Source:pushCategoryAsync(stable_id)
    local row = require("book.books_db").get(self.id, stable_id)
    local category = row and row.category or nil
    local client = self._client
    return client:shelfSyncAsync(function(wire, err)
        if not wire then
            logger.warn("wechat group sync failed", err)
            return
        end
        local steps = {}
        local target, joined
        for _idx, archive in ipairs(type(wire.archive) == "table" and wire.archive or {}) do
            local ids, has = {}, false
            for _i, id in ipairs(archive.bookIds or {}) do
                if tostring(id) == stable_id then has = true else ids[#ids + 1] = tostring(id) end
            end
            if archive.name == category then
                target = archive
                joined = has
            elseif has then
                steps[#steps + 1] = { archive.archiveId, archive.name, ids }
            end
        end
        if category and not joined then
            local ids = {}
            for _i, id in ipairs(target and target.bookIds or {}) do
                if tostring(id) ~= stable_id then ids[#ids + 1] = tostring(id) end
            end
            ids[#ids + 1] = stable_id
            steps[#steps + 1] = { target and target.archiveId or os.time(), category, ids }
        end
        local function run(index)
            local step = steps[index]
            if not step then return end
            client:saveArchiveAsync(step[1], step[2], step[3], function(data, push_err)
                if not data then
                    logger.warn("wechat group push failed", push_err)
                    return
                end
                run(index + 1)
            end)
        end
        run(1)
    end)
end

--- 关闭这个实例：清实例自己的封面表。Context（psvts）与 Toc 是进程级的，
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

--- 本进程是否已清过旧版同步进书库的公众号行（Mp.dropLegacyBooks）。
local legacy_mp_dropped = false

---@param opts { dirty_only?: boolean, force?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return table
function Source:syncBooksAsync(opts, cb)
    if not legacy_mp_dropped then
        legacy_mp_dropped = true
        require("source.wechat.mp").dropLegacyBooks(require("book.books_db"))
    end
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
        require("ui/uimanager"):nextTick(require("ui.guard").wrap("wechat callback", function()
            if not cancelled then cb(cached) end
        end))
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

--- 用户点开的章取不到正文：进入一页临时提示文档（不当缓存，下次打开重新拉），不挡在阅读器外面。
--- 没登录不算（要走登录流程）；预取 / 整本缓存不用它，照常失败。
---@param r BookIdentity
---@param chapter BookChapter
---@param done fun(payload: ChapterContentPayload|nil, err: any)
local function openContent(r, chapter, done)
    return WChapter.fetchContentAsync(r.stable_id, chapter, function(payload, err)
        if payload or not Auth.hasSession() then
            done(payload, err)
            return
        end
        local title = chapter.title or ""
        local notice = string.format(_("这一章暂时无法加载：%s\n请稍后重试。"), tostring(err))
        done({ title = title, html = Text.chapterHtml(title, notice), temporary = true })
    end)
end

--- 按章打开：目录与正文都交给 source.chapter 的带 UI 流程。
---@param identity BookIdentity
---@param opts table|nil 可含 chapter_idx 指定章节
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:openBookAsync(identity, opts, cb)
    return require("source.chapter").openWithUi(self, identity, identity.book, opts, {
        loadToc = function(r, done) return self:loadTocAsync(r, done) end,
        fetchContent = openContent,
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
---@param cb fun(ok: boolean|nil, err: string|nil, meta: table|nil)
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
            if cancelled then return end
            if wire then
                cb(true)
            else
                cb(nil, push_err)
            end
        end)
    end
    local missing = _("缺少章节信息")
    if chapter_uid then
        startPush(chapter_uid)
    elseif not (tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)) then
        -- 手动标已读写入的 100% 行没有章节：按末章读完上报；其余没有章节的行永远推不上，标为永久失败让同步丢弃。
        if frac < 1 then
            require("ui/uimanager"):nextTick(function()
                if not cancelled then cb(nil, missing, { permanent = true }) end
            end)
        else
            resolve_job = self:loadTocAsync(identity, function(toc)
                if cancelled then return end
                local last = type(toc) == "table" and #toc or 0
                local uid = last > 0 and Toc.uid(identity.source_id, identity.stable_id, last) or nil
                if not uid then
                    cb(nil, missing, { permanent = true })
                    return
                end
                chapter_idx, offset, progress = last, 10000, 100
                startPush(uid)
            end)
        end
    else
        resolve_job = resolveChapterUidAsync(self, identity, chapter_idx, function(uid, err)
            if cancelled then return end
            if not uid then
                cb(nil, err or missing)
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

--- 按 App 协议（``/book/read``）上报本地阅读时长，一本书一个请求，时长按小时分桶，
--- 离线攒下的时段联网后照原时间补报。成功的书确认其全部行，失败就停，其余行留给下一轮。
--- 书目录没缓存（定位不到章节）的行无法上报，直接确认丢弃，免得卡住队首。
---@param rows table[]|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:pushStatsAsync(rows, cb)
    local synced = {}
    local order, books = {}, {}
    for _idx, row in ipairs(rows or {}) do
        local book = books[row.stable_id]
        if not book then
            book = { id = row.stable_id, rows = {} }
            books[row.stable_id] = book
            order[#order + 1] = book
        end
        book.rows[#book.rows + 1] = row
    end
    local cancelled, job = false, nil
    local function finish(err)
        if #synced == 0 and err then
            cb(nil, err)
        else
            cb({ ok = true, synced_ids = synced })
        end
    end
    local function confirm(book)
        for _idx, row in ipairs(book.rows) do synced[#synced + 1] = row.id end
    end
    job = self._client:guestTokenAsync(function(token, token_err)
        if cancelled then return end
        if not token then
            finish(token_err)
            return
        end
        local creds = Eink.credentials()
        if not creds then
            finish(_("请先扫码登录微信读书墨水屏"))
            return
        end
        local index = 0
        local function nextBook()
            index = index + 1
            local book = order[index]
            if not book then
                finish()
                return
            end
            local last = book.rows[#book.rows]
            local chapter_idx = last.chapter_idx
            local uid = chapter_idx and Toc.uid("wechat", book.id, chapter_idx, true)
            if not uid then
                logger.warn("wechat stats skipped without toc", book.id)
                confirm(book)
                nextBook()
                return
            end
            local fraction = Progress.clampFraction(last.chapter_fraction)
            local body = App.readBody({
                vid = creds.vid,
                device_id = creds.device_id,
                install_id = Eink.installId(),
                guest_token = token,
                book_id = book.id,
                chapter_uid = tonumber(uid) or 0,
                chapter_idx = Toc.sourceIndex("wechat", book.id, chapter_idx, true) or chapter_idx,
                chapter_offset = math.floor(fraction * 10000),
                chapter_progress = math.floor(fraction * 100),
                hours = App.hours(book.rows, App.timeZone()),
            })
            job = self._client:reportAppReadAsync(body, function(data, err)
                if cancelled then return end
                if not data then
                    logger.warn("wechat app report failed", book.id, err)
                    finish(err)
                    return
                end
                confirm(book)
                nextBook()
            end)
        end
        nextBook()
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
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
                if not reviews then
                    local local_items = {}
                    for _idx, row in ipairs(require("book.note_db").all(identity.source_id, identity.stable_id)) do
                        for _j, item in ipairs((require("book.note.normalize").decode(row.payload)) or {}) do
                            item.chapter_idx = item.chapter_idx or (row.chapter_idx > 0 and row.chapter_idx or nil)
                            local_items[#local_items + 1] = item
                        end
                    end
                    Notes.keepLocalReviews(annotations, local_items)
                end
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
---@param cb fun(ok: boolean|nil, err: string|nil, meta: table|nil)
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

--- 按书名搜索微信读书书目（关联本地书看段评用）。
---@param keyword string
---@param cb fun(books: WechatSearchBook[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:searchBooksAsync(keyword, cb)
    return self._client:searchAsync(keyword, function(wire, err)
        if not wire then
            cb(nil, err)
            return
        end
        cb(Mapper.searchBooks(wire))
    end)
end

--- 书城搜索：回包形状同 listStoreAsync。
---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:searchAsync(keyword, cb)
    return self._client:searchAsync(keyword, function(wire, err)
        if not wire then
            cb(nil, err)
            return
        end
        cb({ data = Mapper.searchList(wire) })
    end)
end

--- 书城浏览：三行 chip（榜单 / 分类 / 所选分类的子分类）+ 所选节点的书，节点是榜单或分类 id，缺省是第一个榜单。
--- 目录树只在实例上缓存精简版；榜单页每次现拉。
---@param opts { node?: string, limit?: integer }
---@param cb fun(res: { data: Book[], groups: table[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Source:browseAsync(opts, cb)
    local handle = {}
    local function load(tree)
        local node = opts.node or (tree.rankings[1] and tree.rankings[1].id)
        if not node then
            cb(nil, _("没有可浏览的榜单"))
            return
        end
        local ranking, top
        for _idx, row in ipairs(tree.rankings) do
            if row.id == node then ranking = row end
        end
        for _idx, cat in ipairs(tree.categories) do
            if cat.id == node then top = cat end
            for _idx2, sub in ipairs(cat.subs) do
                if sub.id == node then top = cat end
            end
        end
        local groups = {
            { chips = tree.rankings, active = ranking and node },
            { chips = tree.categories, active = top and top.id },
        }
        if top then
            local subs = { { id = top.id, title = _("全部") } }
            for _idx, sub in ipairs(top.subs) do subs[#subs + 1] = sub end
            groups[3] = { chips = subs, active = node }
        end
        handle.inner = Browse.pages(function(page, done)
            return self._client:storeBooksAsync(node, (page - 1) * 20, ranking ~= nil, function(wire, err)
                if not wire then
                    done(nil, err)
                    return
                end
                done(Mapper.searchList(wire), nil, wire.hasMore == 1)
            end)
        end, opts.limit or 60, groups, cb)
    end
    if self._store_tree then
        load(self._store_tree)
    else
        handle.inner = self._client:storeCategoriesAsync(function(wire, err)
            if not wire then
                cb(nil, err)
                return
            end
            self._store_tree = Mapper.storeTree(wire)
            load(self._store_tree)
        end)
    end
    function handle.cancel()
        if handle.inner then handle.inner:cancel() end
    end
    return handle
end

--- 本章有段评的热点原句（未定位）。
---@param identity BookIdentity 微信书身份，chapter_idx 为微信目录序号
---@param cb fun(hotspots: WechatReviewHotspot[]|nil, err: string|nil)
---@return { cancel: fun() }
function Source:paragraphHotspotsAsync(identity, cb)
    return ReviewCache.hotspotsAsync(identity, function(done)
        return withChapterUid(self, identity, done, function(chapter_uid, finish)
            return Reviews.hotspotsAsync(self._client, identity.stable_id, chapter_uid, finish)
        end)
    end, cb)
end

--- 热点按原句定位到 html（xpointer 以该 HTML 的根为起点）；定位不了的丢弃。
---@param hotspots WechatReviewHotspot[]
---@param html string
---@return WechatReviewSpot[]
function Source:locateHotspots(hotspots, html)
    return Reviews.locate(hotspots, html)
end

--- 某句的一页段评。
---@param identity BookIdentity
---@param range string 热点的 range
---@param max_idx integer 首页 0，之后用上一页回传的 max_idx
---@param cb fun(page: WechatReviewPage|nil, err: string|nil)
---@return { cancel: fun() }
function Source:paragraphReviewPageAsync(identity, range, max_idx, cb)
    return ReviewCache.pageAsync(identity, range, max_idx, function(done)
        return withChapterUid(self, identity, done, function(chapter_uid, finish)
            return Reviews.pageAsync(self._client, identity.stable_id, chapter_uid, range, max_idx, finish)
        end)
    end, cb)
end

return WeChat
