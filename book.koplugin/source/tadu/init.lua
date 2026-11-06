--[[--
塔读数据源。

微信扫码登录后同步网页书架。目录来自阅读页，正文按目录顺序取
getPartContentByCodeTable。书城搜索和频道不需要登录。

@module koplugin.book.source.tadu
--]]

require("l10n").apply()
local Browse = require("source.browse")
local Client = require("source.tadu.client")
local Mapper = require("source.tadu.mapper")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("gettext")

local Tadu = {}

local FETCH_INTERVAL = 0.5

local CHANNELS = {
    { id = "98-a-0-15-a-20-p-1-98", title = "男频" },
    { id = "122-a-0-15-a-20-p-1-122", title = "女频" },
    { id = "79-a-0-15-a-20-p-1-79", title = "出版" },
}

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
        cb({ data = Mapper.books(html) })
    end)
end

---@param opts { node?: string }|nil
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
function Source:browseAsync(opts, cb)
    local node = opts and opts.node or CHANNELS[1].id
    local known = false
    local chips = {}
    for _idx, channel in ipairs(CHANNELS) do
        chips[#chips + 1] = { id = channel.id, title = _(channel.title) }
        if channel.id == node then known = true end
    end
    if not known then node = CHANNELS[1].id end
    return Client.channelAsync(node, function(html, err)
        if not html then cb(nil, err or _("请求失败")); return end
        cb({ data = Mapper.books(html), groups = { Browse.group(chips, node) } })
    end)
end

function Source:getDetailAsync(identity, cb)
    return Client.detailAsync(identity.stable_id, function(html, err)
        local detail = Mapper.detail(html, identity.stable_id)
        if detail then cb(require("book.store").rememberDetail(detail)); return end
        local row = identity.book or require("book.books_db").get(self.id, identity.stable_id)
        if row then cb(row); return end
        cb(nil, err or _("请求失败"))
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
local function fetcher()
    return function(identity, chapter, done)
        local part = chapter.source_idx or tostring(chapter.idx)
        return Client.contentAsync(identity.stable_id, part, function(html, err)
            if html then done({ title = chapter.title, html = html }); return end
            done(nil, err)
        end)
    end
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = fetcher(),
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

return Tadu
