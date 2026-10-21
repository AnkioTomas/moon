--[[--
潇湘书院数据源。

搜索、目录、榜单走 PC / 手机站页面，账号、正文、书架、进度走新站 xxsypro.com 的 JSON 接口（client.lua）。
登录态是新站 Cookie（阅文通行证，只有 QQ / 微信 / 阅文账号，没有扫码）：浏览器扩展授权，或粘贴 Cookie（setting.lua）。
书架双向同步（Shelf.syncAsync），进度按章：读书架行的 ccid，写 readingProcess/add。没买的 VIP 章开章给临时提示页，目录标「未购」。

@module koplugin.book.source.xiaoxiang
--]]

local Client = require("source.xiaoxiang.client")
local Mapper = require("source.xiaoxiang.mapper")
local SourceBase = require("source.base")
local Browse = require("source.browse")
local Shelf = require("source.shelf")
local Toc = require("source.toc")
local _ = require("gettext")

local Xiaoxiang = {}

-- 接口按 IP 限流，预取与整本缓存逐章间隔请求。
local FETCH_INTERVAL = 1

---@return BookSourceMeta
function Xiaoxiang.meta()
    return { id = "xiaoxiang", name = _("潇湘书院"), type = "chapter" }
end

---@class XiaoxiangSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return XiaoxiangSource
function Xiaoxiang.new()
    local meta = Xiaoxiang.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

--- 搜索 / 目录 / 榜单匿名可用，书架、进度和已购 VIP 章要登录 Cookie。
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
        require("utils.log").warn("book xiaoxiang tombstone remove failed", identity.stable_id)
    end
    return SourceBase.defer(cb, true)
end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "xiaoxiang not logged in") end
    return Shelf.syncAsync(self.id, Remote, Mapper.shelfList, opts, cb)
end

function Source:syncNotesAsync(_opts, cb)
    return SourceBase.skipped(cb, "xiaoxiang has no notes")
end

function Source:syncStatsAsync(_opts, cb)
    return SourceBase.skipped(cb, "xiaoxiang has no stats")
end

--- 进度只到章：读书架行里这本书最近读到的章（ccid）。
function Source:getProgressAsync(identity, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录潇湘")) end
    local cancelled, job = false, nil
    job = Client.shelfAsync(function(rows, err)
        if cancelled then return end
        if not rows then cb(nil, err); return end
        local uid = Mapper.progress(rows)[tostring(identity.stable_id)]
        if not uid then cb(nil, nil, { empty = true }); return end
        job = self:loadTocAsync(identity, function(toc, reason)
            if cancelled then return end
            if not toc or #toc == 0 then cb(nil, reason or _("潇湘目录为空")); return end
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

function Source:putProgressAsync(identity, pos, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录潇湘")) end
    local cancelled, job = false, nil
    job = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then cb(nil, err); return end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter then cb(nil, _("缺少潇湘章节位置")); return end
        job = Client.progressAsync(identity.stable_id, chapter.uid, function(wire, perr) cb(wire and true, perr) end)
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
    return Client.searchAsync(keyword, function(books, err)
        if not books then
            cb(nil, err)
            return
        end
        cb({ data = books })
    end)
end

-- 手机站 /rank/<id> 的榜单，顺序同网页。
local RANKS = {
    { id = "xxyuepiao", title = "潇湘票榜" },
    { id = "bestsales", title = "畅销榜" },
    { id = "finish", title = "完结榜" },
    { id = "reading", title = "阅读榜" },
    { id = "collections", title = "收藏榜" },
}

---@param opts { node?: string, limit?: integer }
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Source:browseAsync(opts, cb)
    local rank = RANKS[1]
    for _idx, row in ipairs(RANKS) do
        if row.id == opts.node then rank = row end
    end
    local chips = {}
    for _idx, row in ipairs(RANKS) do chips[#chips + 1] = { id = row.id, title = _(row.title) } end
    local groups = { Browse.group(chips, rank.id) }
    return Client.rankAsync(rank.id, function(books, err)
        if not books then cb(nil, err); return end
        cb({ data = books, groups = groups })
    end)
end

function Source:getDetailAsync(identity, cb)
    return SourceBase.defer(cb, identity.book or require("book.books_db").get(self.id, identity.stable_id))
end

function Source:loadTocAsync(identity, cb)
    local cached = Toc.read(self.id, identity.stable_id)
    if cached and #cached > 0 and cached[1].toc_version == Mapper.TOC_VERSION then
        return SourceBase.defer(cb, cached)
    end
    return Client.chaptersAsync(identity.stable_id, function(toc, err)
        if not toc then cb(nil, err); return end
        if #toc == 0 then cb(nil, _("潇湘目录为空")); return end
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

return Xiaoxiang
