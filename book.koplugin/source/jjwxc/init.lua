--[[--
晋江文学城数据源。

书的元数据 / 目录 / 免费章正文走匿名 App 接口，VIP 章与个人收藏走手机网页 Cookie（client.lua）。
登录是浏览器登录态的 Cookie（setting.lua）；登录后收藏双向同步（source.shelf）：拉取、本地删除上行。
最近阅读页能读到章，但没有确认能写回的接口，进度不接，避免只拉不推。笔记和统计没有接口。

@module koplugin.book.source.jjwxc
--]]

local Client = require("source.jjwxc.client")
local Mapper = require("source.jjwxc.mapper")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("gettext")

local Jjwxc = {}

-- 接口按 IP 限流，预取与整本缓存逐章间隔请求。
local FETCH_INTERVAL = 1

---@return BookSourceMeta
function Jjwxc.meta()
    return { id = "jjwxc", name = _("晋江文学城"), type = "chapter" }
end

---@class JjwxcSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return JjwxcSource
function Jjwxc.new()
    local meta = Jjwxc.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

---@return boolean
function Source:configured()
    return Client.cookie() ~= nil
end

--- 收藏页的书名是截断的：本地没有完整元数据（封面是标志）的书逐本补拉详情，拉不到就退回页面上的书名。
---@param rows table[]
---@param cb fun(rows: table[])
---@return { cancel: fun() }
local function fillDetails(rows, cb)
    local BookDB = require("book.books_db")
    local cancelled, job, index = false, nil, 0
    local function nextRow()
        if cancelled then return end
        index = index + 1
        local row = rows[index]
        if not row then cb(rows); return end
        row.local_book = BookDB.get(Jjwxc.meta().id, row.id)
        local cover = row.local_book and row.local_book.cover
        if cover and cover ~= "" then nextRow(); return end
        row.local_book = nil
        job = Client.detailAsync(row.id, function(info, err)
            if cancelled then return end
            if info then
                row.info = info
            else
                require("utils.log").warn("book jjwxc detail failed", row.id, err)
            end
            nextRow()
        end)
    end
    nextRow()
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

--- 书架远端：Shelf.syncAsync 要的三个冒号方法。
local Remote = {}

function Remote:shelfSyncAsync(cb)
    local cancelled, job, fill = false, nil, nil
    job = Client.favAsync(Client.cookie(), function(rows, err)
        if cancelled then return end
        if not rows then cb(nil, err); return end
        fill = fillDetails(rows, cb)
    end)
    return { cancel = function()
        cancelled = true
        job.cancel()
        if fill then fill.cancel() end
    end }
end

--- 网页收藏要过数美设备校验，月读暂时加不进去。
function Remote:addToShelfAsync(_stable_id, cb)
    return SourceBase.defer(cb, nil, _("晋江暂不支持从月读加入收藏"))
end

function Remote:removeFromShelfAsync(stable_id, cb)
    return Client.favRemoveAsync(stable_id, cb)
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
        require("utils.log").warn("book jjwxc tombstone remove failed", identity.stable_id)
    end
    return SourceBase.defer(cb, true)
end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "jjwxc not logged in") end
    return Shelf.syncAsync(self.id, Remote, Mapper.shelfList, opts, cb)
end

function Source:syncProgressAsync(_opts, cb)
    return SourceBase.skipped(cb, "jjwxc has no remote")
end

function Source:syncNotesAsync(_opts, cb)
    return SourceBase.skipped(cb, "jjwxc has no remote")
end

function Source:syncStatsAsync(_opts, cb)
    return SourceBase.skipped(cb, "jjwxc has no remote")
end

function Source:getProgressAsync(_identity, cb)
    return SourceBase.defer(cb, nil, nil, { empty = true })
end

function Source:putProgressAsync(_identity, _pos, cb)
    return SourceBase.defer(cb, true)
end

--- 书库里已有的元数据（收藏同步时已补全）。
--- 书城搜索：匿名 App 接口，只取第一页。
---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:searchAsync(keyword, cb)
    return Client.searchAsync(keyword, function(wire, err)
        if not wire then
            cb(nil, err)
            return
        end
        cb({ data = Mapper.search(wire) })
    end)
end

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
        if #toc == 0 then cb(nil, _("晋江目录为空")); return end
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

return Jjwxc
