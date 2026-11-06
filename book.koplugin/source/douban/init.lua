--[[--
豆瓣阅读数据源。

搜索和免费章节不需要登录。书架在 App 扫码后同步。
进度按作品拉取；专栏再按章节 article 记一条，网站打开该章才能续上。
阅读时长走 /j/reading_time。未购买的章节给一页提示，不当成缓存。

@module koplugin.book.source.douban
--]]

require("l10n").apply()
local Client = require("source.douban.client")
local Mapper = require("source.douban.mapper")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Text = require("utils.text")
local Toc = require("source.toc")
local _ = require("gettext")

local Douban = {}

---@return BookSourceMeta
function Douban.meta()
    return SourceBase.loadMeta("douban")
end

---@class DoubanSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return DoubanSource
function Douban.new()
    local meta = Douban.meta()
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
    if not self:configured() then return SourceBase.skipped(cb, "douban not logged in") end
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

function Source:getDetailAsync(identity, cb)
    return Client.detailAsync(identity.stable_id, function(book, err)
        if book then cb(require("book.store").rememberDetail(book)); return end
        local row = identity.book or require("book.books_db").get(self.id, identity.stable_id)
        if row then cb(row); return end
        cb(nil, err or _("请求失败"))
    end)
end

---@param self DoubanSource
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
local function fetchTocAsync(self, identity, cb)
    return Client.tocAsync(identity.stable_id, function(toc, err)
        if not toc then cb(nil, err); return end
        if #toc == 0 then cb(nil, _("豆瓣阅读目录为空")); return end
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

---@param self DoubanSource
---@param open boolean
---@return ChapterFetchContent
local function fetcher(self, open)
    return function(_identity, chapter, done)
        if chapter.vip then
            if not open then done(nil, _("本章未购买")); return end
            local notice = string.format(_("这是 VIP 章节，你还没有购买。\n请先在%s购买本章，再回来阅读。"), self.name)
            done({ title = chapter.title, html = Text.chapterHtml(chapter.title, notice), temporary = true })
            return
        end
        local start_pid = chapter.slice and tonumber(chapter.uid) or nil
        local end_pid = chapter.slice and tonumber(chapter.end_pid) or nil
        return Client.textAsync(chapter.content_url, start_pid, end_pid, function(text, err)
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

---@param toc BookChapter[]
---@param paragraph_id string
---@return integer|nil
local function chapterAt(toc, paragraph_id)
    local pid = tonumber(paragraph_id)
    for idx, chapter in ipairs(toc) do
        if chapter.uid == paragraph_id then return idx end
        if chapter.slice and pid then
            local start_pid = tonumber(chapter.uid)
            local end_pid = tonumber(chapter.end_pid)
            if start_pid and pid >= start_pid and (not end_pid or pid < end_pid) then return idx end
        end
    end
    return nil
end

function Source:getProgressAsync(identity, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录豆瓣阅读")) end
    local cancelled, job = false, nil
    job = Client.progressAsync(identity.stable_id, function(mark, err)
        if cancelled then return end
        if err then cb(nil, err); return end
        if not mark then cb(nil, nil, { empty = true }); return end
        job = self:loadTocAsync(identity, function(toc, reason)
            if cancelled then return end
            if not toc or #toc == 0 then cb(nil, reason or _("豆瓣阅读目录为空")); return end
            local idx = chapterAt(toc, mark.paragraph_id)
            if not idx then cb(nil, nil, { empty = true }); return end
            cb({
                chapter_idx = idx,
                chapter_title = toc[idx].title,
                fraction = (idx - 1) / #toc,
                extra = { chapter_uid = toc[idx].uid, chapter_idx = idx },
            })
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

function Source:putProgressAsync(identity, pos, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录豆瓣阅读")) end
    local cancelled, job = false, nil
    job = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then cb(nil, err); return end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter then cb(nil, _("缺少豆瓣阅读章节位置")); return end
        local function posted(ok, perr)
            if cancelled then return end
            cb(ok and true or nil, perr)
        end
        if chapter.slice then
            job = Client.putProgressAsync(identity.stable_id, chapter.uid, idx, #toc, true, posted)
            return
        end
        -- 专栏阅读器按章节 article 取进度，作品 id 上的记录只给月读自己对上章节。
        job = Client.putProgressAsync(identity.stable_id, chapter.uid, idx, #toc, false, function(ok, perr)
            if cancelled then return end
            if not ok then cb(nil, perr); return end
            job = Client.articleAsync(chapter.uid, function(article, article_err)
                if cancelled then return end
                if not article then cb(nil, article_err); return end
                local pid = Mapper.firstParagraphId(article)
                if not pid then cb(nil, _("缺少豆瓣阅读章节位置")); return end
                job = Client.putProgressAsync(chapter.uid, pid, idx, #toc, false, posted)
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

---@param seconds integer
---@return string
local function iso(seconds)
    return os.date("!%Y-%m-%dT%H:%M:%S", seconds) .. ".000Z"
end

function Source:pushStatsAsync(rows, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录豆瓣阅读")) end
    local sessions, ids = {}, {}
    for _idx, row in ipairs(rows or {}) do
        local start_time = tonumber(row.start_time)
        local duration = tonumber(row.duration)
        if row.id and start_time and duration and duration > 0 and type(row.stable_id) == "string" and row.stable_id ~= "" then
            sessions[#sessions + 1] = {
                worksId = tonumber(row.stable_id) or row.stable_id,
                beginTime = iso(start_time),
                endTime = iso(start_time + duration),
            }
            ids[#ids + 1] = row.id
        elseif row.id then
            ids[#ids + 1] = row.id
        end
    end
    if #sessions == 0 then return SourceBase.defer(cb, { synced_ids = ids }) end
    return Client.pushReadingAsync(sessions, function(ok, err)
        if not ok then cb(nil, err); return end
        cb({ synced_ids = ids })
    end)
end

function Source:paragraphReviewsEnabled()
    return require("source.review_setting").enabled(self.id)
end

---@param identity BookIdentity
---@param cb fun(chapter: BookChapter|nil, err: string|nil)
---@return { cancel: fun() }
local function chapterOf(self, identity, cb)
    local cancelled, job = false, nil
    job = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        local chapter = toc and toc[tonumber(identity.chapter_idx)]
        if not chapter or type(chapter.content_url) ~= "string" or chapter.content_url == "" then
            cb(nil, err or _("豆瓣阅读目录为空"))
            return
        end
        cb(chapter)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

function Source:paragraphHotspotsAsync(identity, cb)
    local cancelled, job = false, nil
    job = chapterOf(self, identity, function(chapter, err)
        if cancelled then return end
        if not chapter then cb(nil, err); return end
        job = require("source.douban.reviews").hotspotsAsync(chapter, cb)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

function Source:locateHotspots(hotspots, html)
    local ReviewLocate = require("book.review_locate")
    return ReviewLocate.locate(ReviewLocate.paragraphs(html), hotspots, html)
end

function Source:paragraphReviewPageAsync(identity, range, _max_idx, cb)
    local cancelled, job = false, nil
    job = chapterOf(self, identity, function(chapter, err)
        if cancelled then return end
        if not chapter then cb(nil, err); return end
        job = require("source.douban.reviews").pageAsync(chapter, range, cb)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

return Douban
