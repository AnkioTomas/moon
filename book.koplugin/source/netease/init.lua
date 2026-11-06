--[[--
网易云阅读数据源。

搜索、榜单和免费章节不需要登录。未购买章节给一页提示。
登录后才能上报阅读位置。登录页没有扫码。
书架列表还没见过登录后的样子，所以不推书架。

@module koplugin.book.source.netease
--]]

require("l10n").apply()
local Browse = require("source.browse")
local Client = require("source.netease.client")
local Mapper = require("source.netease.mapper")
local SourceBase = require("source.base")
local Text = require("utils.text")
local Toc = require("source.toc")
local _ = require("gettext")

local Netease = {}

---@return BookSourceMeta
function Netease.meta()
    return SourceBase.loadMeta("netease")
end

---@class NeteaseSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return NeteaseSource
function Netease.new()
    local meta = Netease.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

--- 免费阅读不需要账号。关掉书架上行，避免没有列表接口时把本地书架推空。
---@return SourceCapabilities
function Source:capabilities()
    local caps = SourceBase.capabilities(self)
    caps.shelf_push = false
    return caps
end

--- 未登录仍可搜索和读免费章节。进度上行只在登录后发生，避免每次唤醒都重试。
---@return boolean
function Source:configured()
    return Client.loggedIn()
end

---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
function Source:searchAsync(keyword, cb)
    return Client.searchAsync(keyword, function(books, err)
        if not books then cb(nil, err or _("请求失败")); return end
        cb({ data = books })
    end)
end

---@param opts { node?: string }|nil
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
function Source:browseAsync(opts, cb)
    local node = opts and opts.node or nil
    if node ~= "female" and node ~= "publish" then node = "male" end
    local chips = {
        { id = "male", title = _("男频") },
        { id = "female", title = _("女频") },
        { id = "publish", title = _("出版") },
    }
    return Client.rankAsync(node, function(books, err)
        if not books then cb(nil, err or _("请求失败")); return end
        cb({ data = books, groups = { Browse.group(chips, node) } })
    end)
end

function Source:getDetailAsync(identity, cb)
    return Client.infoAsync(identity.stable_id, function(wire, err)
        local detail = wire and Mapper.detail(wire)
        if detail then cb(require("book.store").rememberDetail(detail)); return end
        local row = identity.book or require("book.books_db").get(self.id, identity.stable_id)
        if row then cb(row); return end
        cb(nil, err or _("请求失败"))
    end)
end

---@param self NeteaseSource
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
local function fetchTocAsync(self, identity, cb)
    return Client.infoAsync(identity.stable_id, function(wire, err)
        if not wire then cb(nil, err); return end
        local toc = Mapper.chapters(wire)
        if not toc or #toc == 0 then cb(nil, _("网易云阅读目录为空")); return end
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

---@param open boolean
---@return ChapterFetchContent
local function fetcher(open)
    return function(identity, chapter, done)
        if chapter.vip then
            if not open then done(nil, _("本章未购买")); return end
            local notice = string.format(_("这是 VIP 章节，你还没有购买。\n请先在%s购买本章，再回来阅读。"), _("网易云阅读"))
            done({ title = chapter.title, html = Text.chapterHtml(chapter.title, notice), temporary = true })
            return
        end
        return Client.contentAsync(identity.stable_id, chapter.uid, function(html, err)
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
        fetchContent = fetcher(true),
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    local Chapter = require("source.chapter")
    return Chapter.prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = fetcher(false),
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    local Chapter = require("source.chapter")
    return Chapter.cacheAllAsync(self, identity, fetcher(false), on_progress, cb, nil, range)
end

function Source:getProgressAsync(identity, cb)
    local cancelled, job = false, nil
    job = Client.infoAsync(identity.stable_id, function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        local toc = Mapper.chapters(wire)
        local idx = Mapper.progressIndex(wire)
        if not toc or not idx or not toc[idx] then cb(nil, nil, { empty = true }); return end
        if not Toc.put(self.id, identity.stable_id, toc) then cb(nil, _("章节目录保存失败")); return end
        cb({
            chapter_idx = idx,
            chapter_title = toc[idx].title,
            fraction = (idx - 1) / #toc,
            extra = { chapter_uid = toc[idx].uid, chapter_idx = idx },
        })
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

function Source:bookReviewsAsync(identity, cb)
    return Client.commentsAsync(identity.stable_id, function(items, err, pages)
        if not items then cb(nil, err); return end
        cb({ items = items, pages = pages })
    end)
end

function Source:putProgressAsync(identity, pos, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录网易云阅读")) end
    local cancelled, job = false, nil
    job = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then cb(nil, err); return end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        if idx then idx = math.floor(idx) end
        local chapter = idx and toc[idx]
        if not chapter or type(chapter.sec_id) ~= "string" or chapter.sec_id == "" then
            cb(nil, _("缺少网易云阅读章节位置"))
            return
        end
        job = Client.putProgressAsync(identity.stable_id, toc, idx, pos.chapter_fraction, function(ok, perr)
            cb(ok and true or nil, perr)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

return Netease
