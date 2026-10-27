--[[--
七猫免费小说数据源。

搜索 / 目录 / 正文走匿名 App 接口（protocol / client，正文解密，按章落盘走公共 source/chapter）；
登录是 PC 网页的 token（setting.lua），登录后书架双向同步（source.shelf，网页书架接口）。
进度只到章：开书从书架行的 latest_read_chapter_id 拉，关书用同一条书架同步接口改这一行。
笔记和统计没有接口。书由书城页按源搜索后加入本地书库。

@module koplugin.book.source.qimao
--]]

local Browse = require("source.browse")
local Client = require("source.qimao.client")
local Mapper = require("source.qimao.mapper")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("gettext")

local Qimao = {}

-- 匿名接口按 IP 限流，预取与整本缓存逐章间隔请求。
local FETCH_INTERVAL = 1

---@return BookSourceMeta
function Qimao.meta()
    return { id = "qimao", name = _("七猫小说"), type = "chapter" }
end

---@class QimaoSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return QimaoSource
function Qimao.new()
    local meta = Qimao.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

---@return boolean
function Source:configured()
    return Client.token() ~= nil
end

--- 书架远端：Shelf.syncAsync 要的三个冒号方法，都是 Client 的网页书架接口。
local Remote = {}

function Remote:shelfSyncAsync(cb) return Client.shelfSyncAsync(cb) end

function Remote:addToShelfAsync(stable_id, cb)
    local row = require("book.books_db").get(Qimao.meta().id, stable_id)
    if not row then return SourceBase.defer(cb, nil, _("本地没有这本书")) end
    return Client.shelfPushAsync({ Mapper.shelfItem(stable_id, row, "1") }, cb)
end

function Remote:removeFromShelfAsync(stable_id, cb)
    return Client.shelfPushAsync({ { book_id = stable_id, updated_at = tostring(os.time()), push_type = "2" } }, cb)
end

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
        require("utils.log").warn("book qimao tombstone remove failed", identity.stable_id)
    end
    return SourceBase.defer(cb, true)
end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "qimao not logged in") end
    return Shelf.syncAsync(self.id, Remote, Mapper.shelfList, opts, cb)
end

function Source:syncNotesAsync(_opts, cb)
    return SourceBase.skipped(cb, "qimao has no notes")
end

function Source:syncStatsAsync(_opts, cb)
    return SourceBase.skipped(cb, "qimao has no stats")
end

function Source:getProgressAsync(identity, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录七猫")) end
    local cancelled, job = false, nil
    job = Client.shelfSyncAsync(function(rows, err)
        if cancelled then return end
        if not rows then cb(nil, err); return end
        local row
        for _idx, item in ipairs(rows) do
            if tostring(item.book_id) == tostring(identity.stable_id) then row = item; break end
        end
        local read = Mapper.readChapter(row)
        if not read then cb(nil, nil, { empty = true }); return end
        job = self:loadTocAsync(identity, function(toc, reason)
            if cancelled then return end
            if not toc or #toc == 0 then cb(nil, reason or _("七猫目录为空")); return end
            local idx = Toc.index(self.id, identity.stable_id, read.uid)
            if not idx then cb(nil, nil, { empty = true }); return end
            cb({
                chapter_idx = idx,
                chapter_title = read.title,
                fraction = (idx - 1) / #toc,
                extra = { chapter_uid = read.uid, chapter_idx = idx },
            })
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

function Source:putProgressAsync(identity, pos, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录七猫")) end
    local cancelled, job = false, nil
    job = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then cb(nil, err); return end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter or not chapter.uid then
            cb(nil, _("缺少七猫章节位置"))
            return
        end
        job = Client.shelfSyncAsync(function(rows, reason)
            if cancelled then return end
            if not rows then cb(nil, reason); return end
            local row
            for _item, item in ipairs(rows) do
                if tostring(item.book_id) == tostring(identity.stable_id) then row = item; break end
            end
            if not row then cb(nil, _("这本书不在七猫书架上")); return end
            job = Client.shelfPushAsync({ Mapper.progressItem(row, {
                uid = chapter.uid, title = chapter.title, idx = idx,
            }) }, function(wire, push_err)
                if cancelled then return end
                cb(wire and true or nil, push_err)
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

--- 书城搜索：匿名接口，只取第一页。
---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:searchAsync(keyword, cb)
    return Client.searchAsync(keyword, 1, function(wire, err)
        if not wire then
            cb(nil, err)
            return
        end
        cb({ data = Mapper.search(wire) })
    end)
end

--- 书城浏览：排序 / 频道 / 分类 / 子分类四行 chip（选项来自书库筛选接口），节点是「频道:分类:子分类:排序」，
--- 缺省男生原创按点击量；选项每次都调 client，新鲜度由数据获取层缓存（source.store_cache）管。
---@param opts { node?: string, limit?: integer }
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Source:browseAsync(opts, cb)
    local handle = {}
    -- 回调同步完成时 load 已换上在途句柄，外层赋值不能再覆盖（同 jdread 的 mine 记法）。
    local step = 0
    local function load(options)
        step = step + 1
        local channel, cat1, cat2, order = (opts.node or "0:a:a:click"):match("^(%w+):(%w+):(%w+)$")
        local function chips(rows, id_of)
            local out = {}
            for _idx, row in ipairs(rows) do
                if row.value ~= "a" then out[#out + 1] = { id = id_of(row.value), title = row.label } end
            end
            return out
        end
        local orders = chips(options.filters.order, function(v) return channel .. ":" .. cat1 .. ":" .. cat2 .. ":" .. v end)
        local channels = chips(options.filters.channel, function(v) return v .. ":a:a:" .. order end)
        local tops, subs = { { id = channel .. ":a:a:" .. order, title = _("全部") } }, nil
        for _idx, cat in ipairs(options.category) do
            if cat.type == channel then
                tops[#tops + 1] = { id = channel .. ":" .. cat.id .. ":a:" .. order, title = cat.name }
                if cat.id == cat1 then
                    subs = { { id = channel .. ":" .. cat1 .. ":a:" .. order, title = _("全部") } }
                    for _idx2, sub in ipairs(cat.children) do
                        subs[#subs + 1] = { id = channel .. ":" .. cat1 .. ":" .. sub.id .. ":" .. order, title = sub.name }
                    end
                end
            end
        end
        local node = channel .. ":" .. cat1 .. ":" .. cat2 .. ":" .. order
        local groups = { Browse.group(orders, node), Browse.group(channels, channel .. ":a:a:" .. order),
            Browse.group(tops, channel .. ":" .. cat1 .. ":a:" .. order) }
        if subs then groups[4] = Browse.group(subs, node) end
        handle.inner = Browse.pages(function(page, done)
            return Client.classifyAsync({ channel = channel, category1 = cat1, category2 = cat2, order = order, page = page },
                function(wire, err)
                    if not wire then
                        done(nil, err)
                        return
                    end
                    local books, more = Mapper.classify(wire)
                    done(books, nil, more)
                end)
        end, opts.limit or 60, groups, cb)
    end
    local first = Client.classifyOptionsAsync(function(wire, err)
        if not wire then
            cb(nil, err)
            return
        end
        load(wire.data)
    end)
    if step == 0 then handle.inner = first end
    function handle.cancel()
        if handle.inner then handle.inner.cancel() end
    end
    return handle
end

--- 书库里已有的元数据；详情只在书城预览时才需要拉。
function Source:getDetailAsync(identity, cb)
    return SourceBase.defer(cb, identity.book or require("book.books_db").get(self.id, identity.stable_id))
end

function Source:loadTocAsync(identity, cb)
    local cached = Toc.read(self.id, identity.stable_id)
    if cached and #cached > 0 then
        return SourceBase.defer(cb, cached)
    end
    local cancelled, job = false, nil
    job = Client.chaptersAsync(identity.stable_id, function(wire, err)
        if cancelled then return end
        local toc = wire and Mapper.toc(wire)
        if not toc then cb(nil, err); return end
        if #toc == 0 then cb(nil, _("七猫目录为空")); return end
        if not Toc.put(self.id, identity.stable_id, toc) then cb(nil, _("章节目录保存失败")); return end
        cb(toc)
    end)
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

---@return ChapterFetchContent
local function contentFetcher()
    return function(identity, chapter, done)
        return Client.contentAsync(identity.stable_id, chapter.uid, function(text, err)
            if not text then done(nil, err); return end
            done({ title = chapter.title, html = require("utils.text").chapterHtml(chapter.title, text) })
        end)
    end
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = contentFetcher(),
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = contentFetcher(),
        interval_seconds = FETCH_INTERVAL,
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    return require("source.chapter").cacheAllAsync(self, identity, contentFetcher(), on_progress, cb,
        FETCH_INTERVAL, range)
end

return Qimao
