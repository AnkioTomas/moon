--[[--
起点中文网数据源。

详情 / 目录 / 章节走手机站页面（client.lua）。登录是浏览器登录态的 Cookie（setting.lua）；
登录后书架双向同步（source.shelf）：拉取、本地加入上行、本地删除上行。
起点网页没有进度 / 笔记 / 统计接口：这三个域只在本地。VIP 章未购买时打开失败。

@module koplugin.book.source.qidian
--]]

require("l10n").apply()
local Client = require("source.qidian.client")
local Mapper = require("source.qidian.mapper")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("gettext")

local Qidian = {}

-- 章节页不小，预取与整本缓存逐章间隔请求。
local FETCH_INTERVAL = 1

---@return BookSourceMeta
function Qidian.meta()
    return { id = "qidian", name = _("起点中文网"), type = "chapter" }
end

---@class QidianSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return QidianSource
function Qidian.new()
    local meta = Qidian.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

---@return boolean
function Source:configured()
    return Client.cookie() ~= nil
end

--- 书架行没有简介。本地没有简介或封面的书逐本补拉详情，拉不到就退回书架行。
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
        row.local_book = BookDB.get(Qidian.meta().id, tostring(row.bid))
        local book = row.local_book
        local intro = book and book.intro
        local cover = book and book.cover
        if intro and intro ~= "" and cover and cover ~= "" then nextRow(); return end
        job = Client.detailAsync(row.bid, function(info, err)
            if cancelled then return end
            if info then
                row.info = info
            else
                require("utils.log").warn("book qidian detail failed", row.bid, err)
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
        require("utils.log").warn("book qidian tombstone remove failed", identity.stable_id)
    end
    return SourceBase.defer(cb, true)
end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "qidian not logged in") end
    return Shelf.syncAsync(self.id, Remote, Mapper.shelfList, opts, cb)
end

function Source:syncProgressAsync(_opts, cb)
    return SourceBase.skipped(cb, "qidian has no remote")
end

function Source:syncNotesAsync(_opts, cb)
    return SourceBase.skipped(cb, "qidian has no remote")
end

function Source:syncStatsAsync(_opts, cb)
    return SourceBase.skipped(cb, "qidian has no remote")
end

function Source:getProgressAsync(_identity, cb)
    return SourceBase.defer(cb, nil, nil, { empty = true })
end

function Source:putProgressAsync(_identity, _pos, cb)
    return SourceBase.defer(cb, true)
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
        if #toc == 0 then cb(nil, _("起点目录为空")); return end
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

return Qidian
