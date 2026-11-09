--[[--
长佩文学网数据源。

网页 JSON 接口（client.lua）：搜索、分类与榜单、详情、目录、正文、书评与章评；登录 Cookie（setting.lua）后已购 VIP 章可读，书架双向同步
（source.shelf，网页书架接口，分组里的书不同步），进度只到章（读阅读历史，写靠取一次当前章）。没有笔记和统计。
没买的 VIP 章开章给临时提示页，目录标「未购」。

@module koplugin.book.source.changpei
--]]

local Browse = require("source.browse")
local Client = require("source.changpei.client")
local Mapper = require("source.changpei.mapper")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("l10n").get("source.changpei")

local Changpei = {}

-- 接口按 IP 限流，预取与整本缓存逐章间隔请求。
local FETCH_INTERVAL = 1

---@return BookSourceMeta
function Changpei.meta()
    return SourceBase.loadMeta("changpei")
end

---@class ChangpeiSource : SourceBase
local Source = setmetatable({ shelf_add = true }, { __index = SourceBase })
Source.__index = Source

---@return ChangpeiSource
function Changpei.new()
    local meta = Changpei.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

--- 搜索 / 目录匿名可用，但读正文和书架、进度都要登录 Cookie。
---@return boolean
function Source:configured()
    return Client.cookie() ~= nil
end

--- 书架远端：Shelf.syncAsync 要的三个冒号方法。
local Remote = {}

function Remote:shelfSyncAsync(cb) return Client.shelfAsync(cb) end

function Remote:addToShelfAsync(stable_id, cb) return Client.shelfAddAsync(stable_id, cb) end

function Remote:removeFromShelfAsync(stable_id, cb) return Client.shelfRemoveAsync(stable_id, cb) end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "changpei not logged in") end
    return Shelf.syncAsync(self.id, Remote, Mapper.shelfList, opts, cb)
end

--- 进度只到章：读阅读历史里这本书最近读到的章。
function Source:getProgressAsync(identity, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录长佩")) end
    local cancelled, job, pending = false, nil, true
    local initial = Client.historyAsync(function(wire, err)
        pending = false
        if cancelled then return end
        if not wire then cb(nil, err); return end
        if type(wire.data) ~= "table" or type(wire.data.list) ~= "table" then
            cb(nil, _("响应无效")); return
        end
        local uid = Mapper.history(wire)[tostring(identity.stable_id)]
        if not uid then cb(nil, nil, { empty = true }); return end
        job = self:loadTocAsync(identity, function(toc, reason)
            if cancelled then return end
            if not toc or #toc == 0 then cb(nil, reason or _("长佩目录为空")); return end
            local idx = Toc.index(self.id, identity.stable_id, uid)
            if not idx then cb(nil, nil, { empty = true }); return end
            cb({
                chapter_idx = idx,
                chapter_title = toc[idx].title,
                fraction = (idx - 1) / #toc,
                extra = { chapter_uid = uid, chapter_idx = idx },
            })
        end)
    end)
    if pending then job = initial end
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

--- 没有写进度的网页接口：取一次当前章，服务端把它记成「读到这里」（预取会把历史推到后面的章，关书时用它拉回来）。
function Source:putProgressAsync(identity, pos, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录长佩")) end
    local cancelled, job, pending = false, nil, true
    local initial = self:loadTocAsync(identity, function(toc, err)
        pending = false
        if cancelled then return end
        if not toc then cb(nil, err); return end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter then cb(nil, _("缺少长佩章节位置")); return end
        job = Client.markReadAsync(chapter.uid, function(ok, reason)
            if not cancelled then cb(ok, reason) end
        end)
    end)
    if pending then job = initial end
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:searchAsync(keyword, cb)
    return Client.searchAsync(keyword, function(wire, err)
        if not wire then
            cb(nil, err)
            return
        end
        if type(wire.data) ~= "table" or type(wire.data.list) ~= "table" then
            cb(nil, _("响应无效")); return
        end
        cb({ data = Mapper.search(wire) })
    end)
end

--- 书城浏览：榜单 / 子榜两行 chip，节点是「榜单号:子榜值」，缺省第一个榜单的第一个子榜。榜单每页 10 本。
---@param opts { node?: string, limit?: integer }
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Source:browseAsync(opts, cb)
    opts = opts or {}
    if not opts.node or opts.node:sub(1, 5) == "cate:" then
        return require("source.changpei.browse").run(opts, cb)
    end
    local handle = {}
    local pending = true
    local initial = Client.rankNavAsync(function(nav, err)
        pending = false
        if handle.cancelled then return end
        if not nav then cb(nil, err); return end
        local ranks = Mapper.ranks(nav)
        if #ranks == 0 then cb(nil, _("长佩榜单为空")); return end
        local rid, tid = (opts.node or ""):match("^(%d+):(%d+)$")
        local rank = ranks[1]
        for _idx, row in ipairs(ranks) do
            if tostring(row.rid) == rid then rank = row end
        end
        tid = tonumber(tid)
        local sub = rank.types[1].value
        for _idx, row in ipairs(rank.types) do
            if row.value == tid then sub = tid end
        end
        local rank_chips, sub_chips = {}, {}
        rank_chips[1] = { id = "cate:0:0:0:2:0:8", title = _("分类书库") }
        for _idx, row in ipairs(ranks) do
            rank_chips[#rank_chips + 1] = { id = row.rid .. ":" .. row.types[1].value, title = row.name }
        end
        for _idx, row in ipairs(rank.types) do
            sub_chips[#sub_chips + 1] = { id = rank.rid .. ":" .. row.value, title = row.name }
        end
        local groups = {
            Browse.group(rank_chips, rank.rid .. ":" .. rank.types[1].value),
            Browse.group(sub_chips, rank.rid .. ":" .. sub),
        }
        local total = 0
        handle.inner = Browse.pages(function(page, done)
            return Client.rankAsync(rank.rid, sub, page, function(wire, reason)
                if not wire then done(nil, reason); return end
                if type(wire.data) ~= "table" or type(wire.data.list) ~= "table" or not tonumber(wire.data.count) then
                    done(nil, _("响应无效")); return
                end
                total = tonumber(wire.data and wire.data.count) or 0
                done(Mapper.search(wire), nil, page * 10 < total)
            end)
        end, opts.limit or 20, groups, cb)
    end)
    if pending then handle.inner = initial end
    return { cancel = function()
        handle.cancelled = true
        if handle.inner then handle.inner.cancel() end
    end }
end

function Source:getDetailAsync(identity, cb)
    if not require("ui/network/manager"):isConnected() then
        return SourceBase.defer(cb, identity.book or require("book.books_db").get(self.id, identity.stable_id))
    end
    return Client.detailAsync(identity.stable_id, function(wire, err)
        if not wire then cb(nil, err); return end
        local book, reason = Mapper.detail(wire)
        if not book then cb(nil, reason); return end
        cb(require("book.store").rememberDetail(book))
    end)
end

function Source:bookReviewsAsync(identity, cb)
    local ref = { source_id = self.id, stable_id = identity.stable_id }
    return require("book.review_cache").pageAsync(ref, "book", 0, function(done)
        return Client.commentsAsync("novel", identity.stable_id, 1, function(wire, err)
            if not wire then done(nil, err); return end
            local page, reason = Mapper.comments(wire, "novel", identity.stable_id, 1)
            if page then page.title = page.more and _("书评预览") or _("书评") end
            done(page, reason)
        end)
    end, cb)
end

function Source:paragraphReviewsEnabled()
    return require("source.review_setting").enabled(self.id)
end

function Source:paragraphReviewPageAsync(identity, range, max_idx, cb)
    if range ~= "chapter" then return SourceBase.defer(cb, nil, _("缺少长佩章节位置")) end
    return require("book.review_cache").pageAsync(identity, range, max_idx, function(done)
        return require("source.with_chapter_uid").run(self, identity, _("缺少长佩章节位置"), function(uid, finish)
            local page = tonumber(max_idx) + 1
            return Client.commentsAsync("chapter", uid, page, function(wire, err)
                if not wire then finish(nil, err); return end
                finish(Mapper.comments(wire, "chapter", uid, page))
            end)
        end, done)
    end, cb)
end

function Source:chapterReviewHotspotsAsync(identity, cb)
    return require("book.review_cache").hotspotsAsync(identity, function(done)
        return self:paragraphReviewPageAsync(identity, "chapter", 0, function(page, err)
            if not page then done(nil, err); return end
            local spots = {}
            if #page.items > 0 then
                spots[1] = { range = "chapter", text = _("本章讨论"), total = page.total,
                    badge = tostring(page.total) .. (page.more and "+" or ""), heading = _("章节评论"),
                    anchor = require("book.review_locate").CHAPTER_ANCHOR }
            end
            done(spots)
        end)
    end, cb)
end

--- 强制拉目录并写回；失败由调用方继续用旧缓存。
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetchTocAsync(self, identity, cb)
    return Client.chaptersAsync(identity.stable_id, function(wire, err)
        if not wire then cb(nil, err); return end
        local toc, reason = Mapper.toc(wire)
        if not toc then cb(nil, reason); return end
        if #toc == 0 then cb(nil, _("长佩目录为空")); return end
        if not Toc.put(self.id, identity.stable_id, toc) then cb(nil, _("章节目录保存失败")); return end
        cb(toc)
    end)
end

---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@param force boolean|nil 真=跳过缓存强制拉
---@return { cancel: fun() }|nil
function Source:loadTocAsync(identity, cb, force)
    if not force then
        local cached = Toc.read(self.id, identity.stable_id)
        if cached and #cached > 0 and (cached[1].toc_version == Mapper.TOC_VERSION
            or not require("ui/network/manager"):isConnected()) then
            return SourceBase.defer(cb, cached)
        end
    end
    return fetchTocAsync(self, identity, cb)
end

Source.refreshTocAsync = fetchTocAsync

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local locate = require("book.review_locate")
    local reviews = self:paragraphReviewsEnabled()
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = Chapter.vipFetcher(self, Client.openContentAsync, true, reviews and locate.prepareChapterEnd or nil),
        reuse = reviews and locate.reuseChapterEnd or nil,
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    local Chapter = require("source.chapter")
    local locate = require("book.review_locate")
    local reviews = self:paragraphReviewsEnabled()
    return Chapter.prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = Chapter.vipFetcher(self, Client.contentAsync, false, reviews and locate.prepareChapterEnd or nil),
        reuse = reviews and locate.reuseChapterEnd or nil,
        interval_seconds = FETCH_INTERVAL,
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    local Chapter = require("source.chapter")
    local prepare = self:paragraphReviewsEnabled() and require("book.review_locate").prepareChapterEnd or nil
    return Chapter.cacheAllAsync(self, identity, Chapter.vipFetcher(self, Client.contentAsync, false, prepare), on_progress, cb,
        FETCH_INTERVAL, range)
end

return Changpei
