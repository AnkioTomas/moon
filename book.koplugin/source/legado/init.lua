--[[--
阅读（Legado / 开源阅读）数据源。

直连阅读 App 的 Web 服务，或 reader3 服务器版（地址可带 /reader3 前缀，再配账号密码，setting.lua 配置）。书架只拉不加（书在阅读 App 里添加），
目录 / 正文按章落盘走公共 source/chapter；进度只到章，开书从书架行的 durChapterIndex 拉，
关书经 /saveBookProgress 上报。笔记和统计没有接口。

@module koplugin.book.source.legado
--]]

local Client = require("source.legado.client")
local Mapper = require("source.legado.mapper")
local Text = require("utils.text")
local Request = require("http.request")
local Assets = require("source.assets")
local Paths = require("utils.paths")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("l10n").get("source.legado")

local Legado = {}

---@return BookSourceMeta
function Legado.meta()
    return SourceBase.loadMeta("legado")
end

---@class LegadoSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return LegadoSource
function Legado.new()
    local meta = Legado.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

---@return boolean
function Source:configured()
    return Client.base() ~= nil
end

---@param rows table[]
---@param stable_id string
---@return table|nil
local function findRow(rows, stable_id)
    for _idx, row in ipairs(rows) do
        if row.bookUrl == stable_id then return row end
    end
    return nil
end

--- 书架远端：Shelf.syncAsync 要的三个冒号方法。书只能在阅读 App 里加，本地没有「加入」入口。
local Remote = {}

function Remote:shelfSyncAsync(cb) return Client.shelfAsync(cb) end

function Remote:addToShelfAsync(_stable_id, cb)
    return SourceBase.defer(cb, nil, _("请在阅读 App 里添加书籍"))
end

--- 远端已经没有这本书就算删除完成。
function Remote:removeFromShelfAsync(stable_id, cb)
    local cancelled, job = false, nil
    job = Client.shelfAsync(function(rows, err)
        if cancelled then return end
        if not rows then cb(nil, err); return end
        local row = findRow(rows, stable_id)
        if not row then cb(true); return end
        job = Client.deleteBookAsync(row, cb)
    end)
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "legado not configured") end
    return Shelf.syncAsync(self.id, Remote, function(rows) return Mapper.shelfList(Client.coverUrl, rows) end, opts, cb)
end

--- 取书架行再交给 fn(row, toc, done)；没配置 / 不在书架上 / 目录空都走 cb 报错。
--- fn 要再发请求就返回它的句柄，取消会传过去；done 是取消后不再投递的 cb。
---@param identity BookIdentity
---@param cb function
---@param fn fun(row: table, toc: BookChapter[], done: function): { cancel: fun() }|nil
---@return { cancel: fun() }
function Source:withRow(identity, cb, fn)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未配置阅读服务器地址")) end
    local cancelled, job = false, nil
    local function done(...)
        if not cancelled then cb(...) end
    end
    job = Client.shelfAsync(function(rows, err)
        if cancelled then return end
        if not rows then cb(nil, err); return end
        local row = findRow(rows, identity.stable_id)
        if not row then cb(nil, _("这本书不在阅读书架上")); return end
        job = self:loadTocAsync(identity, function(toc, reason)
            if cancelled then return end
            if not toc then cb(nil, reason); return end
            job = fn(row, toc, done) or job
        end)
    end)
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

function Source:getProgressAsync(identity, cb)
    return self:withRow(identity, cb, function(row, toc)
        local read = Mapper.readPos(row)
        if not read then cb(nil, nil, { empty = true }); return end
        local idx = math.min(read.index + 1, #toc)
        cb({
            chapter_idx = idx,
            chapter_title = read.title or toc[idx].title,
            fraction = (idx - 1) / #toc,
            extra = { chapter_uid = toc[idx].uid, chapter_idx = idx },
        })
    end)
end

function Source:putProgressAsync(identity, pos, cb)
    return self:withRow(identity, cb, function(row, toc, done)
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter then cb(nil, _("缺少阅读章节位置")); return end
        local read = Mapper.readPos(row)
        local same = read and read.index == idx - 1
        return Client.saveProgressAsync(row, {
            index = idx - 1,
            title = chapter.title,
            offset = same and read.offset or 0,
        }, done)
    end)
end

--- 书库里已有的元数据。
function Source:getDetailAsync(identity, cb)
    return SourceBase.defer(cb, identity.book or require("book.books_db").get(self.id, identity.stable_id))
end

--- 强制拉目录并写回；失败由调用方继续用旧缓存。轻阅读按书源取，先从书架行查 origin。
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }
local function fetchTocAsync(self, identity, cb)
    local cancelled, job = false, nil
    local function fetch(origin)
        job = Client.chaptersAsync(identity.stable_id, origin, function(rows, err)
            if cancelled then return end
            if not rows then cb(nil, err); return end
            local toc = Mapper.toc(rows, origin)
            if #toc == 0 then cb(nil, _("阅读目录为空")); return end
            if not Toc.put(self.id, identity.stable_id, toc) then cb(nil, _("章节目录保存失败")); return end
            cb(toc)
        end)
    end
    if Client.mode() ~= "qread" then
        fetch(nil)
    else
        job = Client.shelfAsync(function(rows, err)
            if cancelled then return end
            local row = rows and findRow(rows, identity.stable_id)
            if not row then cb(nil, err or _("这本书不在阅读书架上")); return end
            fetch(row.origin)
        end)
    end
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@param force boolean|nil 真=跳过缓存强制拉
---@return { cancel: fun() }
function Source:loadTocAsync(identity, cb, force)
    if not force then
        local cached = Toc.read(self.id, identity.stable_id)
        if cached and #cached > 0 then
            return SourceBase.defer(cb, cached)
        end
    end
    return fetchTocAsync(self, identity, cb)
end

Source.refreshTocAsync = fetchTocAsync

---@return ChapterFetchContent
local function contentFetcher(reviews)
    return function(identity, chapter, done)
        local cancelled = false
        ---@type { job: CancelHandle|nil }|nil
        local active
        ---@param start fun(cb: function): CancelHandle|nil
        ---@param finish function
        local function run(start, finish)
            local stage = {}
            active = stage
            stage.job = start(function(...)
                if cancelled or active ~= stage then return end
                active = nil
                finish(...)
            end)
        end
        local function fetchAsset(path)
            local url = Text.escapeUrl(Client.imageUrl(path))
            run(function(cb)
                return Request.get(url, { timeout = 20 }, cb)
            end, function(raw, err)
                if not raw or raw == "" then done(nil, err or _("阅读章节内容为空")); return end
                local html = Mapper.assetHtml(chapter.title, raw, url, Client.imageUrl)
                if not html then done(nil, _("阅读章节内容为空")); return end
                local image_err
                run(function(cb)
                    return Assets.localizeAsync(html, Paths.bookWorkDir(identity.stable_id, identity.source_id) .. "/images",
                        function(image_url, on_done)
                            return Request.get(image_url, { timeout = 45 }, function(data, reason)
                                if reason then image_err = tostring(reason) end
                                on_done(data, reason)
                            end)
                        end, cb)
                end, function(localized)
                    if Text.hasRemoteImageSrc(localized) then
                        done(nil, image_err or _("阅读插图下载失败，请重试"))
                        return
                    end
                    done({ title = chapter.title, html = localized })
                end)
            end)
        end
        run(function(cb)
            return Client.contentAsync(identity.stable_id, tonumber(chapter.uid), chapter.origin, cb)
        end, function(text, err)
            if not text then done(nil, err); return end
            -- 只有 reader3 的明确资源前缀才是 EPUB 路径，不能按 .html 后缀猜正文类型。
            if Client.mode() == "reader3" and text:find("^/book%-assets/") then
                fetchAsset(text)
                return
            end
            local html = Mapper.chapterHtml(chapter.title, text, Client.imageUrl, Client.mode() == "app")
            -- 只有 <h1> 没有段落 = 服务器给的是空白正文，不能当成功落盘缓存。
            if not html:find("<p", 1, true) then done(nil, _("阅读章节内容为空")); return end
            done({ title = chapter.title,
                html = reviews and require("book.review_locate").prepareChapterEnd(html) or html })
        end)
        return { cancel = function()
            cancelled = true
            local job = active and active.job
            active = nil
            if job then job.cancel() end
        end }
    end
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local reviews = self:paragraphReviewsEnabled()
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = contentFetcher(reviews),
        reuse = reviews and require("book.review_locate").reuseChapterEnd or nil,
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    local reviews = self:paragraphReviewsEnabled()
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = contentFetcher(reviews),
        reuse = reviews and require("book.review_locate").reuseChapterEnd or nil,
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    return require("source.chapter").cacheAllAsync(self, identity, contentFetcher(self:paragraphReviewsEnabled()),
        on_progress, cb, 0, range)
end

function Source:paragraphReviewsEnabled()
    return Client.mode() == "app" and require("source.review_setting").enabled(self.id)
end

local function hotspotsAsync(self, identity, cb)
    return require("book.review_cache").hotspotsAsync(identity, function(done)
        return require("source.with_chapter_uid").run(self, identity, _("缺少阅读章节位置"), function(uid, finish)
            return Client.reviewSummaryAsync(identity.stable_id, tonumber(uid), function(data, err)
                if data == nil then finish(nil, err or _("阅读段评响应无效")); return end
                finish(require("source.legado.reviews").hotspots(data))
            end)
        end, done)
    end, cb)
end

function Source:paragraphHotspotsAsync(identity, cb)
    return hotspotsAsync(self, identity, function(list, err)
        if not list then cb(nil, err); return end
        local out = {}
        for _idx, spot in ipairs(list) do
            if spot.paragraph > 0 then out[#out + 1] = spot end
        end
        cb(out)
    end)
end

function Source:chapterReviewHotspotsAsync(identity, cb)
    return hotspotsAsync(self, identity, function(list, err)
        if not list then cb(nil, err); return end
        local out = {}
        for _idx, spot in ipairs(list) do
            if spot.paragraph == -1 then
                out[#out + 1] = { range = spot.range, text = _("本章讨论"), total = spot.total,
                    badge = tostring(spot.total), heading = _("章节评论"),
                    anchor = require("book.review_locate").CHAPTER_ANCHOR }
            end
        end
        cb(out)
    end)
end

function Source:locateHotspots(hotspots, html)
    return require("source.legado.reviews").locate(hotspots, html)
end

local function reviewPageAsync(self, identity, range, max_idx, reply, cb)
    local Reviews = require("source.legado.reviews")
    local context, err = Reviews.context(range, reply)
    if not context then return SourceBase.defer(cb, nil, err) end
    local page, cursor, reason = Reviews.pagination(max_idx)
    if not page then return SourceBase.defer(cb, nil, reason) end
    return require("book.review_cache").pageAsync(identity, (reply and "reply:" or "") .. range, max_idx, function(done)
        return require("source.with_chapter_uid").run(self, identity, _("缺少阅读章节位置"), function(uid, finish)
            local function onPage(data, error)
                if data == nil then finish(nil, error or _("阅读段评响应无效")); return end
                finish(Reviews.page(data, context, page))
            end
            if reply then
                return Client.reviewRepliesAsync(identity.stable_id, tonumber(uid), context[1], context[2],
                    context[3], page, onPage)
            end
            return Client.reviewDetailAsync(identity.stable_id, tonumber(uid), context[1], context[2],
                page, cursor, onPage)
        end, done)
    end, cb)
end

function Source:paragraphReviewPageAsync(identity, range, max_idx, cb)
    return reviewPageAsync(self, identity, range, max_idx, false, cb)
end

function Source:paragraphReviewRepliesAsync(identity, review_id, max_idx, cb)
    return reviewPageAsync(self, identity, review_id, max_idx, true, cb)
end

return Legado
