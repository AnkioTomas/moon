--[[--
豆瓣阅读数据源。

搜索和免费章节不需要登录。书架在 App 扫码后同步。
进度按作品拉取；专栏再按章节 article 记一条，网站打开该章才能续上。
阅读时长走 /j/reading_time。未购买的章节给一页提示，不当成缓存。

@module koplugin.book.source.douban
--]]

require("l10n").apply()
local Client = require("source.douban.client")
local Browse = require("source.browse")
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

function Source:capabilities()
    local caps = SourceBase.capabilities(self)
    caps.stats_pull = true
    return caps
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

---@param opts { node?: string, limit?: integer }|nil
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
function Source:browseAsync(opts, cb)
    local limit = opts and opts.limit or 60
    local channel, category, sort, pay, state = (opts and opts.node or ""):match(
        "^(%a+):(%d+):([%a_]+):(%a+):(%a+)$")
    if channel ~= "publish" then channel = "original" end
    local root = channel == "original" and "0" or "1"
    category, sort, pay, state = category or root, sort or "hot", pay or "all", state or "all"
    local sorts = {
        { id = "hot", title = _("热门") }, { id = "new", title = _("最新") },
        { id = "sales", title = _("销量") }, { id = "rating", title = _("好评") },
    }
    if channel == "publish" then
        state = "all"
        sorts[#sorts + 1] = { id = "price_asc", title = _("价格最低") }
        sorts[#sorts + 1] = { id = "book_rating", title = _("豆瓣高分") }
    end
    local valid_sort = false
    for _idx, row in ipairs(sorts) do if row.id == sort then valid_sort = true end end
    if not valid_sort then sort = "hot" end
    if pay ~= "free" and (pay ~= "paid" or channel ~= "publish") then pay = "all" end
    if state ~= "serial" and state ~= "complete" then state = "all" end
    local handle, pending = {}, true
    local initial = Client.categoriesAsync(function(categories, err)
        pending = false
        if handle.cancelled then return end
        if not categories then cb(nil, err); return end
        local valid_category = category == root
        for _idx, row in ipairs(categories[channel]) do if row.id == category then valid_category = true end end
        if not valid_category then category = root end
        local values = { channel, category, sort, pay, state }
        local function chips(title, rows, position)
            local list = {}
            for _idx, row in ipairs(rows) do
                local node = { unpack(values) }
                node[position] = row.id
                if position == 1 then node[2], node[3], node[4], node[5] = row.id == "publish" and "1" or "0", "hot", "all", "all" end
                list[#list + 1] = { id = table.concat(node, ":"), title = row.title }
            end
            local current = { unpack(values) }
            if position == 1 then current[2], current[3], current[4], current[5] = root, "hot", "all", "all" end
            local group = Browse.group(list, table.concat(current, ":"))
            group.title = title
            return group
        end
        local cats = { { id = root, title = _("全部") } }
        for _idx, row in ipairs(categories[channel]) do cats[#cats + 1] = row end
        local prices = { { id = "all", title = _("全部") }, { id = "free", title = _("免费") } }
        if channel == "publish" then prices[#prices + 1] = { id = "paid", title = _("付费") } end
        local groups = {
            chips(nil, { { id = "original", title = _("原创") }, { id = "publish", title = _("出版") } }, 1),
            chips(_("分类"), cats, 2),
            chips(_("排序"), sorts, 3),
            chips(_("价格"), prices, 4),
        }
        if channel == "original" then
            groups[#groups + 1] = chips(_("状态"), {
                { id = "all", title = _("全部") }, { id = "serial", title = _("连载中") },
                { id = "complete", title = _("已完结") },
            }, 5)
        end
        handle.job = Browse.pages(function(page, done)
            return Client.catalogAsync({ category = category, sort = sort, pay = pay, state = state }, page, done)
        end, limit, groups, function(result, reason)
            if result then
                for idx = #result.data, limit + 1, -1 do result.data[idx] = nil end
            end
            if not handle.cancelled then cb(result, reason) end
        end)
    end)
    if pending then handle.job = initial end
    function handle.cancel()
        handle.cancelled = true
        if handle.job then handle.job.cancel() end
    end
    return handle
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
        if cached and #cached > 0 and (cached[1].toc_version == Mapper.TOC_VERSION
            or not require("ui/network/manager"):isConnected()) then
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
            if text then
                local html = Text.chapterHtml(chapter.title, text)
                if not chapter.slice and self:paragraphReviewsEnabled() then
                    html = require("book.review_locate").prepareChapterEnd(html)
                end
                done({ title = chapter.title, html = html })
                return
            end
            done(nil, err)
        end)
    end
end

local function reuseChapterEnd(self, identity)
    if not self:paragraphReviewsEnabled() then return nil end
    return function(path)
        local toc = Toc.read(self.id, identity.stable_id)
        if toc and toc[1] and not toc[1].slice then
            return require("book.review_locate").reuseChapterEnd(path)
        end
        return true
    end
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = fetcher(self, true),
        reuse = reuseChapterEnd(self, identity),
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    local Chapter = require("source.chapter")
    return Chapter.prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = fetcher(self, false),
        reuse = reuseChapterEnd(self, identity),
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    local Chapter = require("source.chapter")
    return Chapter.cacheAllAsync(self, identity, fetcher(self, false), on_progress, cb, nil, range,
        reuseChapterEnd(self, identity))
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
    local cancelled, progress_job, toc_job = false, nil, nil
    progress_job = Client.progressAsync(identity.stable_id, function(mark, err)
        if cancelled then return end
        if err then cb(nil, err); return end
        if not mark then cb(nil, nil, { empty = true }); return end
        toc_job = self:loadTocAsync(identity, function(toc, reason)
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
        if progress_job then progress_job.cancel() end
        if toc_job then toc_job.cancel() end
    end }
end

function Source:putProgressAsync(identity, pos, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录豆瓣阅读")) end
    local cancelled = false
    local toc_job, works_job, article_job
    toc_job = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then cb(nil, err); return end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter then cb(nil, _("缺少豆瓣阅读章节位置")); return end
        local function posted(ok, perr)
            if cancelled then return end
            cb(ok and true or nil, perr)
        end
        article_job = Client.articleAsync(chapter.content_url, function(article, article_err)
            if cancelled then return end
            if not article then cb(nil, article_err); return end
            local pid = chapter.slice and chapter.uid or Mapper.firstParagraphId(article)
            local position = pid and Mapper.progressPosition(article, pid, chapter.end_pid)
            if not position then cb(nil, _("缺少豆瓣阅读章节位置")); return end
            local works_id = chapter.slice and identity.stable_id or chapter.content_url
            works_job = Client.putProgressAsync(works_id, position.paragraph_id, idx, #toc, chapter.slice == true, posted, position)
        end)
    end)
    return { cancel = function()
        cancelled = true
        for _idx, job in pairs({ toc_job, works_job, article_job }) do
            job.cancel()
        end
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

function Source:pullStatsAsync(cb)
    local fetched_at = os.time()
    local date = os.date("*t", fetched_at)
    date.day, date.hour, date.min, date.sec = date.day - 29, 0, 0, 0
    date.isdst = nil
    local begin_date = os.date("%Y-%m-%d", os.time(date))
    return Client.readingStatsAsync(begin_date, function(wire, err)
        if not wire then cb(nil, err); return end
        cb(Mapper.readingStats(wire, begin_date, fetched_at))
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
    local cancelled, chapter_job, review_job = false, nil, nil
    chapter_job = chapterOf(self, identity, function(chapter, err)
        if cancelled then return end
        if not chapter then cb(nil, err); return end
        review_job = require("source.douban.reviews").hotspotsAsync(chapter, function(rows, reason)
            if not cancelled then cb(rows, reason) end
        end)
    end)
    return { cancel = function()
        cancelled = true
        if chapter_job then chapter_job.cancel() end
        if review_job then review_job.cancel() end
    end }
end

function Source:locateHotspots(hotspots, html)
    local ReviewLocate = require("book.review_locate")
    return ReviewLocate.locate(ReviewLocate.paragraphs(html), hotspots, html)
end

function Source:paragraphReviewPageAsync(identity, range, max_idx, cb)
    if range == "chapter" then
        return require("book.review_cache").pageAsync(identity, range, max_idx, function(done)
            return require("source.with_chapter_uid").run(self, identity, _("豆瓣阅读目录为空"),
                function(uid, finish)
                    return Client.communityAsync(identity.stable_id, uid, max_idx, finish)
                end, done)
        end, cb)
    end
    local cancelled, chapter_job, review_job = false, nil, nil
    chapter_job = chapterOf(self, identity, function(chapter, err)
        if cancelled then return end
        if not chapter then cb(nil, err); return end
        review_job = require("source.douban.reviews").pageAsync(chapter, range, function(page, reason)
            if not cancelled then cb(page, reason) end
        end)
    end)
    return { cancel = function()
        cancelled = true
        if chapter_job then chapter_job.cancel() end
        if review_job then review_job.cancel() end
    end }
end

function Source:bookReviewsAsync(identity, cb)
    local ref = { source_id = self.id, stable_id = identity.stable_id }
    return require("book.review_cache").pageAsync(ref, "book", 0, function(done)
        return Client.communityAsync(identity.stable_id, nil, 0, done)
    end, cb)
end

function Source:chapterReviewHotspotsAsync(identity, cb)
    return self:paragraphReviewPageAsync(identity, "chapter", 0, function(page, err)
        if not page then cb(nil, err); return end
        if page.unsupported then cb({}); return end
        cb({ { range = "chapter", text = identity.book and identity.book.title or "",
            total = page.total, badge = tostring(page.total), heading = _("章节评论"),
            anchor = require("book.review_locate").CHAPTER_ANCHOR } })
    end)
end

return Douban
