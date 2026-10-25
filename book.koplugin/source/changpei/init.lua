--[[--
长佩文学网数据源。

网页 JSON 接口（client.lua）：搜索、书城榜单浏览、目录、正文；登录 Cookie（setting.lua）后已购 VIP 章可读，书架双向同步
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
local _ = require("gettext")

local Changpei = {}

-- 接口按 IP 限流，预取与整本缓存逐章间隔请求。
local FETCH_INTERVAL = 1

---@return BookSourceMeta
function Changpei.meta()
    return require("source.meta").get("changpei")
end

---@class ChangpeiSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
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

--- 未登录时书库就是唯一真相：标删后直接撕墓碑；登录后走基类三段式，由书架同步推删。
---@param identity BookIdentity
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function Source:deleteBookAsync(identity, cb)
    if self:configured() then return SourceBase.deleteBookAsync(self, identity, cb) end
    if not require("book.store").markDeleted(self.id, identity.stable_id) then
        return SourceBase.defer(cb, false, _("删除本书失败"))
    end
    if not require("book.books_db").remove(self.id, identity.stable_id) then
        require("utils.log").warn("book changpei tombstone remove failed", identity.stable_id)
    end
    return SourceBase.defer(cb, true)
end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "changpei not logged in") end
    return Shelf.syncAsync(self.id, Remote, Mapper.shelfList, opts, cb)
end

function Source:syncNotesAsync(_opts, cb)
    return SourceBase.skipped(cb, "changpei has no notes")
end

function Source:syncStatsAsync(_opts, cb)
    return SourceBase.skipped(cb, "changpei has no stats")
end

--- 进度只到章：读阅读历史里这本书最近读到的章。
function Source:getProgressAsync(identity, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录长佩")) end
    local cancelled, job = false, nil
    job = Client.historyAsync(function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
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
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

--- 没有写进度的网页接口：取一次当前章，服务端把它记成「读到这里」（预取会把历史推到后面的章，关书时用它拉回来）。
function Source:putProgressAsync(identity, pos, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录长佩")) end
    local cancelled, job = false, nil
    job = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then cb(nil, err); return end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter then cb(nil, _("缺少长佩章节位置")); return end
        job = Client.markReadAsync(chapter.uid, cb)
    end)
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
        cb({ data = Mapper.search(wire) })
    end)
end

--- 书城浏览：榜单 / 子榜两行 chip，节点是「榜单号:子榜值」，缺省第一个榜单的第一个子榜。榜单每页 10 本。
---@param opts { node?: string, limit?: integer }
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Source:browseAsync(opts, cb)
    local handle = {}
    handle.inner = Client.rankNavAsync(function(nav, err)
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
                total = tonumber(wire.data and wire.data.count) or 0
                done(Mapper.search(wire), nil, page * 10 < total)
            end)
        end, opts.limit or 20, groups, cb)
    end)
    return { cancel = function()
        if handle.inner then handle.inner.cancel() end
    end }
end

function Source:getDetailAsync(identity, cb)
    return SourceBase.defer(cb, identity.book or require("book.books_db").get(self.id, identity.stable_id))
end

function Source:loadTocAsync(identity, cb)
    local cached = Toc.read(self.id, identity.stable_id)
    if cached and #cached > 0 and cached[1].toc_version == Mapper.TOC_VERSION then
        return SourceBase.defer(cb, cached)
    end
    return Client.chaptersAsync(identity.stable_id, function(wire, err)
        local toc = wire and Mapper.toc(wire)
        if not toc then cb(nil, err); return end
        if #toc == 0 then cb(nil, _("长佩目录为空")); return end
        if not Toc.put(self.id, identity.stable_id, toc) then cb(nil, _("章节目录保存失败")); return end
        cb(toc)
    end)
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = Chapter.vipFetcher(self, Client.contentAsync, true),
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    local Chapter = require("source.chapter")
    return Chapter.prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = Chapter.vipFetcher(self, Client.contentAsync, false),
        interval_seconds = FETCH_INTERVAL,
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    local Chapter = require("source.chapter")
    return Chapter.cacheAllAsync(self, identity, Chapter.vipFetcher(self, Client.contentAsync, false), on_progress, cb,
        FETCH_INTERVAL, range)
end

return Changpei
