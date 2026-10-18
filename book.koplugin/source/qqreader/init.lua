--[[--
QQ阅读数据源。

目录 / 章节走 book.qq.com 的 JSON 接口（client.lua）。登录是浏览器登录态的 Cookie（setting.lua）；
登录后书架双向同步（source.shelf）：拉取、本地加入上行、本地删除上行。
进度只到章：开书从详情的 lastReadChapterId 拉，关书经 update/reading/process 推。书不在书架上不推，也不加回去。
笔记和统计没有接口。付费章未授权、或字体加密时打开失败。

@module koplugin.book.source.qqreader
--]]

require("l10n").apply()
local Client = require("source.qqreader.client")
local Mapper = require("source.qqreader.mapper")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("gettext")

local QQReader = {}

-- 章节不小，预取与整本缓存逐章间隔请求。
local FETCH_INTERVAL = 1

---@return BookSourceMeta
function QQReader.meta()
    return { id = "qqreader", name = _("QQ阅读"), type = "chapter" }
end

---@class QQReaderSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return QQReaderSource
function QQReader.new()
    local meta = QQReader.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

---@return boolean
function Source:configured()
    return Client.cookie() ~= nil
end

--- 书架行没有简介。本地没有简介的书逐本补拉详情，拉不到就退回书架行。
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
        row.local_book = BookDB.get(QQReader.meta().id, tostring(row.bid))
        local intro = row.local_book and row.local_book.intro
        if intro and intro ~= "" then nextRow(); return end
        job = Client.detailAsync(row.bid, function(info, err)
            if cancelled then return end
            if info then
                row.info = info
            else
                require("utils.log").warn("book qqreader detail failed", row.bid, err)
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
    job = Client.shelfAsync(Client.cookie(), function(rows, err)
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

function Remote:addToShelfAsync(stable_id, cb)
    return Client.addAsync(stable_id, cb)
end

function Remote:removeFromShelfAsync(stable_id, cb)
    return Client.removeAsync(stable_id, cb)
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
        require("utils.log").warn("book qqreader tombstone remove failed", identity.stable_id)
    end
    return SourceBase.defer(cb, true)
end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "qqreader not logged in") end
    return Shelf.syncAsync(self.id, Remote, Mapper.shelfList, opts, cb)
end

function Source:syncNotesAsync(_opts, cb)
    return SourceBase.skipped(cb, "qqreader has no notes")
end

function Source:syncStatsAsync(_opts, cb)
    return SourceBase.skipped(cb, "qqreader has no stats")
end

--- 详情上的 lastReadChapterId 就是书架行那一章。0 是没读过。
function Source:getProgressAsync(identity, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录 QQ阅读")) end
    local cancelled, job = false, nil
    job = Client.detailAsync(identity.stable_id, function(info, err)
        if cancelled then return end
        if not info then cb(nil, err); return end
        local read = Mapper.readChapter(info)
        if not read then cb(nil, nil, { empty = true }); return end
        job = self:loadTocAsync(identity, function(toc, reason)
            if cancelled then return end
            if not toc or #toc == 0 then cb(nil, reason or _("QQ阅读目录为空")); return end
            local idx = Toc.index(self.id, identity.stable_id, read.uid)
            if not idx then cb(nil, nil, { empty = true }); return end
            local chapter = toc[idx]
            cb({
                chapter_idx = idx,
                chapter_title = chapter and chapter.title,
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
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录 QQ阅读")) end
    local cancelled, job = false, nil
    job = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then cb(nil, err); return end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter or not chapter.uid then
            cb(nil, _("缺少 QQ阅读章节位置"))
            return
        end
        job = Client.detailAsync(identity.stable_id, function(info, reason)
            if cancelled then return end
            if not info then cb(nil, reason); return end
            if not Mapper.onShelf(info) then cb(nil, _("这本书不在 QQ阅读书架上")); return end
            job = Client.updateReadAsync(identity.stable_id, chapter.uid, function(ok, push_err)
                if cancelled then return end
                cb(ok and true or nil, push_err)
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

--- 书城搜索：回包形状同 listStoreAsync。
---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:searchAsync(keyword, cb)
    return Client.searchAsync(keyword, function(books, err)
        if not books then
            cb(nil, err)
            return
        end
        cb({ data = books })
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
    job = Client.catalogAsync(identity.stable_id, function(data, err)
        if cancelled then return end
        local toc = data and Mapper.toc(data)
        if not toc then cb(nil, err); return end
        if #toc == 0 then cb(nil, _("QQ阅读目录为空")); return end
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

return QQReader
