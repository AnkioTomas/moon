--[[--
书旗数据源。

搜索、分类和免费章节不需要登录。书架在验证码登录后用书签同步。
未购买的 VIP 章给一页提示，不当成缓存。

@module koplugin.book.source.shuqi
--]]

require("l10n").apply()
local Browse = require("source.browse")
local Client = require("source.shuqi.client")
local Mapper = require("source.shuqi.mapper")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Text = require("utils.text")
local Toc = require("source.toc")
local _ = require("gettext")

local Shuqi = {}

---@return BookSourceMeta
function Shuqi.meta()
    return SourceBase.loadMeta("shuqi")
end

---@class ShuqiSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return ShuqiSource
function Shuqi.new()
    local meta = Shuqi.meta()
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
    if not self:configured() then return SourceBase.skipped(cb, "shuqi not logged in") end
    return Shelf.syncAsync(self.id, Remote, function(books) return books end, opts, cb)
end

---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
function Source:searchAsync(keyword, cb)
    return Client.searchAsync(keyword, function(books, err)
        if not books then cb(nil, err or _("请求失败")); return end
        cb({ data = books })
    end)
end

---@param wire table|nil
---@param node string|nil
---@return StoreChipGroup[], string|nil
local function groupsOf(wire, node)
    local channels = wire and Mapper.channels(wire) or nil
    if not channels then return {}, node end
    local specs = {
        { key = "male", title = _("男频") },
        { key = "female", title = _("女频") },
        { key = "press", title = _("出版") },
    }
    local groups = {}
    local picked = node
    for _idx, spec in ipairs(specs) do
        local chips = channels[spec.key]
        if chips and chips[1] then
            if not picked or picked == "" then picked = chips[1].id end
            groups[#groups + 1] = Browse.group(chips, picked)
            groups[#groups].title = spec.title
        end
    end
    return groups, picked
end

---@param opts { node?: string }|nil
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
function Source:browseAsync(opts, cb)
    local handle = {}
    handle.job = Client.categoriesAsync(function(wire)
        local groups, tag = groupsOf(wire, opts and opts.node)
        handle.job = Client.rankAsync(tag, function(books, err)
            if not books then cb(nil, err or _("请求失败")); return end
            cb({ data = books, groups = groups })
        end)
    end)
    return { cancel = function()
        if handle.job and handle.job.cancel then handle.job.cancel() end
    end }
end

function Source:getDetailAsync(identity, cb)
    return Client.detailAsync(identity.stable_id, function(book, err)
        if book then cb(require("book.store").rememberDetail(book)); return end
        local row = identity.book or require("book.books_db").get(self.id, identity.stable_id)
        if row then cb(row); return end
        cb(nil, err or _("请求失败"))
    end)
end

---@param self ShuqiSource
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
local function fetchTocAsync(self, identity, cb)
    return Client.chaptersAsync(identity.stable_id, function(toc, err)
        if not toc then cb(nil, err); return end
        if #toc == 0 then cb(nil, _("书旗目录为空")); return end
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

---@param self ShuqiSource
---@param open boolean
---@return ChapterFetchContent
local function fetcher(self, open)
    return function(identity, chapter, done)
        if chapter.vip and (type(chapter.content_url) ~= "string" or chapter.content_url == "") then
            if not open then done(nil, _("本章未购买")); return end
            local notice = string.format(_("这是 VIP 章节，你还没有购买。\n请先在%s购买本章，再回来阅读。"), self.name)
            done({ title = chapter.title, html = Text.chapterHtml(chapter.title, notice), temporary = true })
            return
        end
        return Client.contentAsync(chapter.content_url, function(text, err)
            if text then done({ title = chapter.title, html = Text.chapterHtml(chapter.title, text) }); return end
            done(nil, err)
        end)
    end
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = fetcher(self, true),
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    local Chapter = require("source.chapter")
    return Chapter.prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = fetcher(self, false),
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    local Chapter = require("source.chapter")
    return Chapter.cacheAllAsync(self, identity, fetcher(self, false), on_progress, cb, nil, range)
end

function Source:getProgressAsync(identity, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录书旗")) end
    local cancelled, job = false, nil
    job = Client.progressAsync(identity.stable_id, function(mark, err)
        if cancelled then return end
        if err then cb(nil, err); return end
        if not mark then cb(nil, nil, { empty = true }); return end
        job = self:loadTocAsync(identity, function(toc, reason)
            if cancelled then return end
            if not toc or #toc == 0 then cb(nil, reason or _("书旗目录为空")); return end
            local idx = Toc.index(self.id, identity.stable_id, mark.chapter_id)
            if not idx then cb(nil, nil, { empty = true }); return end
            local fraction = mark.fraction
            if not fraction or fraction <= 0 then fraction = (idx - 1) / #toc end
            cb({
                chapter_idx = idx,
                chapter_title = toc[idx].title,
                fraction = fraction,
                extra = { chapter_uid = mark.chapter_id, chapter_idx = idx },
            })
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

function Source:putProgressAsync(identity, pos, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录书旗")) end
    local cancelled, job = false, nil
    job = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then cb(nil, err); return end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter then cb(nil, _("缺少书旗章节位置")); return end
        job = Client.putProgressAsync(identity.stable_id, chapter.uid, chapter.title, idx / #toc, function(ok, perr)
            cb(ok and true or nil, perr)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

return Shuqi
