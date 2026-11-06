--[[--
知乎盐选。没有云端书架，只在本地留下打开过的书。

一节一篇。`is_fold` 不是 false 就是没买，打开时给购买提示，不把预览当正文。

@module source.zhihu
--]]

require("l10n").apply()
local Client = require("source.zhihu.client")
local Mapper = require("source.zhihu.mapper")
local SourceBase = require("source.base")
local Text = require("utils.text")
local Toc = require("source.toc")
local _ = require("gettext")

local Zhihu = {}

---@return BookSourceMeta
function Zhihu.meta()
    return SourceBase.loadMeta("zhihu")
end

---@class ZhihuSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return ZhihuSource
function Zhihu.new()
    local meta = Zhihu.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

--- 没有可对账的云端书架。
---@return SourceCapabilities
function Source:capabilities()
    local caps = SourceBase.capabilities(self)
    caps.shelf_push = false
    return caps
end

---@return boolean
function Source:configured()
    return true
end

---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
function Source:searchAsync(keyword, cb)
    return Client.searchAsync(keyword, function(books, err)
        if not books then cb(nil, err or _("请求失败")); return end
        cb({ data = books })
    end)
end

---@param _opts table|nil
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
function Source:browseAsync(_opts, cb)
    return Client.browseAsync(function(books, err)
        if not books then cb(nil, err or _("请求失败")); return end
        cb({ data = books })
    end)
end

---@param self ZhihuSource
---@param identity BookIdentity
---@param cb fun(wire: table|nil, err: string|nil)
local function loadSimple(self, identity, cb)
    return Client.simpleAsync(identity.stable_id, function(wire, err)
        if not wire then cb(nil, err); return end
        local chapters = Mapper.chapters(wire, identity.stable_id)
        if not chapters then cb(nil, _("请求失败")); return end
        if not Toc.put(self.id, identity.stable_id, chapters) then cb(nil, _("章节目录保存失败")); return end
        wire.chapters = chapters
        wire.book = Mapper.detail(wire, identity.stable_id)
        cb(wire)
    end)
end

function Source:getDetailAsync(identity, cb)
    return loadSimple(self, identity, function(wire, err)
        if wire and wire.book then cb(require("book.store").rememberDetail(wire.book)); return end
        local row = identity.book or require("book.books_db").get(self.id, identity.stable_id)
        if row then cb(row); return end
        cb(nil, err or _("请求失败"))
    end)
end

function Source:loadTocAsync(identity, cb, force)
    if not force then
        local cached = Toc.read(self.id, identity.stable_id)
        if cached and #cached > 0 and cached[1].toc_version == Mapper.TOC_VERSION then
            return SourceBase.defer(cb, cached)
        end
    end
    return loadSimple(self, identity, function(wire, err)
        if not wire then cb(nil, err); return end
        cb(wire.chapters)
    end)
end

Source.refreshTocAsync = function(self, identity, cb)
    return self:loadTocAsync(identity, cb, true)
end

---@param open boolean
---@return ChapterFetchContent
local function fetcher(open)
    return function(identity, chapter, done)
        if chapter.vip then
            if not open then done(nil, _("本章未购买")); return end
            local notice = string.format(_("这是 VIP 章节，你还没有购买。\n请先在%s购买本章，再回来阅读。"), _("知乎盐选"))
            done({ title = chapter.title, html = Text.chapterHtml(chapter.title, notice), temporary = true })
            return
        end
        return Client.contentAsync(identity.stable_id, function(html, err)
            if html then done({ title = chapter.title, html = html }); return end
            done(nil, err)
        end)
    end
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local open_fn = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open_fn(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = fetcher(true),
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = fetcher(false),
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    return require("source.chapter").cacheAllAsync(self, identity, fetcher(false), on_progress, cb, nil, range)
end

return Zhihu
