--[[--
知乎盐选。没有云端书架，只在本地留下打开过的书。

短篇一节一篇，长篇按专栏目录阅读。未购买章节只给购买提示，不把预览当正文。

@module source.zhihu
--]]

require("l10n").apply()
local Client = require("source.zhihu.client")
local Mapper = require("source.zhihu.mapper")
local SourceBase = require("source.base")
local Browse = require("source.browse")
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

function Source:paragraphReviewsEnabled()
    return require("source.review_setting").enabled(self.id)
end

---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
function Source:searchAsync(keyword, cb)
    return Client.searchAsync(keyword, function(books, err)
        if not books then cb(nil, err or _("请求失败")); return end
        cb({ data = books })
    end)
end

local RANKS = {
    { type = "recommend", title = _("推荐榜") },
    { type = "hot_search", title = _("热搜榜") },
    { type = "hot", title = _("热度榜") },
    { type = "reputation", title = _("口碑榜") },
    { type = "well", title = _("长篇榜") },
}

---@param opts { node?: string }|nil
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
function Source:browseAsync(opts, cb)
    local rank, filter = (opts and opts.node or "recommend:0"):match("^([%w_]+):(%d+)$")
    local ranks, known = {}, false
    for _idx, item in ipairs(RANKS) do
        ranks[#ranks + 1] = { id = item.type .. ":0", title = item.title }
        if item.type == rank then known = true end
    end
    if not known then rank, filter = "recommend", "0" end
    local node = rank .. ":" .. filter
    return Client.browseAsync(rank, filter, function(books, err, filters)
        if not books then cb(nil, err or _("请求失败")); return end
        local categories = {}
        for _idx, item in ipairs(filters) do
            categories[#categories + 1] = { id = rank .. ":" .. item.key, title = _(Text.trim(item.name)) }
        end
        cb({ data = books, groups = { Browse.group(ranks, rank .. ":0"), Browse.group(categories, node) } })
    end)
end

---@param self ZhihuSource
---@param identity BookIdentity
---@param cb fun(wire: table|nil, err: string|nil)
local function loadBook(self, identity, cb)
    local fetch = identity.stable_id:match("^%d+$") and Client.catalogAsync or Client.simpleAsync
    return fetch(identity.stable_id, function(wire, err)
        if not wire then cb(nil, err); return end
        local chapters = Mapper.chapters(wire, identity.stable_id)
        if not chapters then cb(nil, _("请求失败")); return end
        if not Toc.put(self.id, identity.stable_id, chapters) then cb(nil, _("章节目录保存失败")); return end
        wire.chapters = chapters
        cb(wire)
    end)
end

function Source:getDetailAsync(identity, cb)
    local function done(book, err)
        if book then
            local stored, save_err = require("book.store").rememberDetail(book)
            if stored and stored.sync_status == 0 then
                local BookDB = require("book.books_db")
                if BookDB.fillEmptyMeta(self.id, identity.stable_id, book.authors, book.intro) then
                    stored = BookDB.get(self.id, identity.stable_id)
                end
            end
            cb(stored, save_err)
            return
        end
        local row = identity.book or require("book.books_db").get(self.id, identity.stable_id)
        if row then cb(row); return end
        cb(nil, err or _("请求失败"))
    end
    if identity.stable_id:match("^%d+$") then
        return Client.detailAsync(identity.stable_id, done)
    end
    return loadBook(self, identity, function(wire, err)
        done(wire and Mapper.detail(wire, identity.stable_id), err)
    end)
end

function Source:loadTocAsync(identity, cb, force)
    if not force then
        local cached = Toc.read(self.id, identity.stable_id)
        if cached and #cached > 0 and cached[1].toc_version == Mapper.TOC_VERSION then
            return SourceBase.defer(cb, cached)
        end
    end
    return loadBook(self, identity, function(wire, err)
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
        local function finish(html, err)
            if html then
                if chapter.vip then Toc.markPaid("zhihu", identity.stable_id, chapter.uid, true) end
                done({ title = chapter.title, html = require("source.zhihu.content").prepare(html) })
                return
            end
            if not open or err ~= _("本章未购买") then done(nil, err); return end
            local notice = string.format(_("这是 VIP 章节，你还没有购买。\n请先在%s购买本章，再回来阅读。"), _("知乎盐选"))
            done({ title = chapter.title, html = Text.chapterHtml(chapter.title, notice), temporary = true })
        end
        if chapter.vip and not Client.cookie() then return finish(nil, _("本章未购买")) end
        local stable_id = identity.stable_id
        if stable_id:match("^%d+$") then stable_id = stable_id .. "/" .. chapter.uid end
        return Client.contentAsync(stable_id, finish)
    end
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local ops = {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = fetcher(true),
        reuse = require("source.zhihu.content").reuse,
    }
    if identity.stable_id:find("/", 1, true) then
        return require("source.zhihu.story").openAsync(self, identity, opts, ops, cb)
    end
    local open_fn = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open_fn(self, identity, identity.book, opts, ops, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = fetcher(false),
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    return require("source.chapter").cacheAllAsync(self, identity, fetcher(false), on_progress, cb, nil, range, nil)
end

function Source:getProgressAsync(identity, cb)
    local cancelled, active = false, nil
    local fired = false
    local job = Client.progressAsync(identity.stable_id, function(record, err, meta)
        fired = true
        if cancelled then return end
        active = nil
        if not record then cb(nil, err, meta); return end
        if identity.stable_id:find("/", 1, true) then
            cb({
                fraction = record.fraction, updated_at = record.updated_at,
                chapter_idx = identity.chapter_idx and 1 or nil,
                chapter_fraction = identity.chapter_idx and record.fraction or nil,
            })
            return
        end
        local function load(force)
            local loaded = false
            local toc_job = self:loadTocAsync(identity, function(toc, toc_err)
                loaded = true
                if cancelled then return end
                active = nil
                if not toc then cb(nil, toc_err); return end
                for idx, chapter in ipairs(toc) do
                    if chapter.uid == record.section_id then
                        cb({
                            fraction = ((idx - 1) + record.fraction) / #toc,
                            chapter_idx = idx, chapter_title = chapter.title,
                            chapter_fraction = record.fraction, updated_at = record.updated_at,
                        })
                        return
                    end
                end
                if not force then load(true); return end
                cb(nil, _("缺少知乎阅读位置"))
            end, force)
            if not loaded then active = toc_job end
        end
        load(false)
    end)
    if not fired then active = job end
    return { cancel = function()
        cancelled = true
        if active then active.cancel() end
    end }
end

function Source:putProgressAsync(identity, pos, cb)
    local _column, section = identity.stable_id:match("^(%d+)/(%d+)$")
    -- 短篇 EPUB 的章号是内部小节，不是知乎的 section；整篇比例才是云端章内比例。
    if section then return Client.putProgressAsync(section, pos.fraction, cb) end
    local cancelled, active = false, nil
    local fired = false
    local job = self:loadTocAsync(identity, function(toc, err)
        fired = true
        if cancelled then return end
        active = nil
        if not toc then cb(nil, err); return end
        local idx = tonumber(pos.chapter_idx) or math.floor(pos.fraction * #toc) + 1
        idx = math.max(1, math.min(#toc, math.floor(idx)))
        local chapter = toc[idx]
        if not chapter then cb(nil, _("缺少知乎阅读位置")); return end
        local within = pos.chapter_fraction
        if within == nil then within = math.max(0, math.min(1, pos.fraction * #toc - (idx - 1))) end
        local posted = false
        local post_job = Client.putProgressAsync(chapter.uid, within, function(ok, post_err)
            posted = true
            if cancelled then return end
            active = nil
            cb(ok, post_err)
        end)
        if not posted then active = post_job end
    end)
    if not fired then active = job end
    return { cancel = function()
        cancelled = true
        if active then active.cancel() end
    end }
end

---@param identity BookIdentity
---@param cb fun(hotspots: WechatReviewHotspot[]|nil, err: string|nil)
function Source:chapterReviewHotspotsAsync(identity, cb)
    return require("book.review_cache").hotspotsAsync(identity, function(done)
        local cancelled, active = false, nil
        local function load(section, title)
            local fired = false
            local job = self:paragraphReviewPageAsync(identity, section, 0, function(page, err)
                fired = true
                if cancelled then return end
                active = nil
                if not page then done(nil, err); return end
                done({ {
                    range = section, text = title, total = page.total,
                    badge = tostring(page.total), heading = _("章节评论"),
                    anchor = require("source.zhihu.content").ANCHOR,
                } })
            end)
            if not fired then active = job end
        end
        local _column, section = identity.stable_id:match("^(%d+)/(%d+)$")
        if section then
            load(section, identity.book and identity.book.title or "")
        else
            local fired = false
            local job = self:loadTocAsync(identity, function(toc, err)
                fired = true
                if cancelled then return end
                active = nil
                local chapter = toc and toc[identity.chapter_idx]
                if not chapter then done(nil, err or _("缺少知乎阅读位置")); return end
                load(chapter.uid, chapter.title)
            end)
            if not fired then active = job end
        end
        return { cancel = function()
            cancelled = true
            if active then active.cancel() end
        end }
    end, cb)
end

function Source:paragraphReviewPageAsync(identity, range, max_idx, cb)
    return require("book.review_cache").pageAsync(identity, range, max_idx, function(done)
        return Client.reviewsAsync(range, max_idx, false, done)
    end, cb)
end

function Source:paragraphReviewRepliesAsync(identity, review_id, max_idx, cb)
    return require("book.review_cache").pageAsync(identity, "reply:" .. review_id, max_idx, function(done)
        return Client.reviewsAsync(review_id, max_idx, true, done)
    end, cb)
end

return Zhihu
