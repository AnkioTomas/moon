--[[--
塔读数据源。

微信扫码登录后同步网页书架。目录来自阅读页，正文按目录顺序取
getPartContentByCodeTable。书城搜索和频道不需要登录。

@module koplugin.book.source.tadu
--]]

local Browse = require("source.browse")
local Client = require("source.tadu.client")
local Mapper = require("source.tadu.mapper")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("l10n").get("source.tadu")

local Tadu = {}

local FETCH_INTERVAL = 0.5

---@return BookSourceMeta
function Tadu.meta()
    return SourceBase.loadMeta("tadu")
end

---@class TaduSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return TaduSource
function Tadu.new()
    local meta = Tadu.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

---@return boolean
function Source:configured()
    return Client.loggedIn()
end

local Remote = {}

function Remote:shelfSyncAsync(cb) return Client.shelfAsync(cb) end

---@param stable_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
function Remote:addToShelfAsync(stable_id, cb)
    return Client.addAsync(stable_id, cb)
end

---@param stable_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
function Remote:removeFromShelfAsync(stable_id, cb)
    return Client.removeAsync(stable_id, cb)
end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "tadu not logged in") end
    return Shelf.syncAsync(self.id, Remote, Mapper.shelf, opts, cb)
end

---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
function Source:searchAsync(keyword, cb)
    return Client.searchAsync(keyword, function(html, err)
        if not html then cb(nil, err or _("请求失败")); return end
        local books = Mapper.listPage(html)
        if not books then cb(nil, _("响应无效")); return end
        cb({ data = books })
    end)
end

---@param opts { node?: string, limit?: integer }|nil
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
function Source:browseAsync(opts, cb)
    local node = opts and opts.node
    if not Mapper.storeNode(node) then node = nil end
    if node then node = Mapper.storePage(node, 1) end
    local handle, pending = {}, true
    local first = Client.channelAsync(node, function(html, err)
        pending = false
        if handle.cancelled then return end
        if not html then cb(nil, err or _("请求失败")); return end
        local groups = Mapper.storeGroups(html)
        local books = Mapper.listPage(html)
        if not books or not groups[1] then cb(nil, _("响应无效")); return end
        local titles = {
            ["频道"] = _("频道"), ["分类"] = _("分类"), ["状态"] = _("状态"),
            ["字数"] = _("字数"), ["排序"] = _("排序"),
        }
        for _idx, group in ipairs(groups) do group.title = titles[group.title] or group.title end
        node = node or groups[1].active
        if not node then cb(nil, _("响应无效")); return end
        handle.inner = Browse.pages(function(page, done)
            if page == 1 then
                done(books, nil, Mapper.storeMore(html, node, page))
                return
            end
            return Client.channelAsync(Mapper.storePage(node, page), function(raw, reason)
                if not raw then done(nil, reason); return end
                local list = Mapper.listPage(raw)
                done(list, not list and _("响应无效") or nil, Mapper.storeMore(raw, node, page))
            end)
        end, opts and opts.limit or 60, groups, cb)
    end)
    if pending then handle.inner = first end
    function handle.cancel()
        handle.cancelled = true
        if handle.inner then handle.inner.cancel() end
    end
    return handle
end

function Source:getDetailAsync(identity, cb)
    return Client.detailAsync(identity.stable_id, function(html, err)
        local detail = Mapper.detail(html, identity.stable_id)
        if detail then cb(require("book.store").rememberDetail(detail)); return end
        cb(nil, err or _("响应无效"))
    end)
end

---@param self TaduSource
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
local function fetchTocAsync(self, identity, cb)
    return Client.chaptersAsync(identity.stable_id, function(html, err)
        if not html then cb(nil, err); return end
        local toc = Mapper.chapters(html)
        if #toc == 0 then cb(nil, _("塔读目录为空")); return end
        if not Toc.put(self.id, identity.stable_id, toc) then cb(nil, _("章节目录保存失败")); return end
        cb(toc)
    end)
end

function Source:loadTocAsync(identity, cb, force)
    if not force then
        local cached = Toc.read(self.id, identity.stable_id)
        if cached and #cached > 0 and cached[1].toc_version == Mapper.TOC_VERSION then
            return SourceBase.defer(cb, cached)
        end
    end
    return fetchTocAsync(self, identity, cb)
end

Source.refreshTocAsync = fetchTocAsync

---@return ChapterFetchContent
local function fetcher(interactive)
    return function(identity, chapter, done)
        local part = chapter.source_idx or tostring(chapter.idx)
        return Client.contentAsync(identity.stable_id, part, function(html, err)
            if html then
                done({ title = chapter.title, html = html })
                return
            end
            done(nil, err)
        end, chapter.uid, interactive)
    end
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = fetcher(true),
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    local Chapter = require("source.chapter")
    return Chapter.prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = fetcher(),
        interval_seconds = FETCH_INTERVAL,
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    local Chapter = require("source.chapter")
    return Chapter.cacheAllAsync(self, identity, fetcher(), on_progress, cb, FETCH_INTERVAL, range)
end

function Source:bookReviewsAsync(identity, cb)
    return Client.reviewsAsync(identity.stable_id, function(items, err, pages)
        if not items then cb(nil, err); return end
        cb({ items = items, pages = pages })
    end)
end

return Tadu
