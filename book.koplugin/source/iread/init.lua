--[[--
iRead（iread.ankio.net）数据源。

个人 Token 鉴权（setting.lua）。书架是服务端的收藏记录，只拉不加（书在网站上搜索收藏），本地删除会上行；
目录 / 正文按章落盘走公共 source/chapter；进度只到章，开书拉取、关书上报。笔记和统计没有接口。
服务端的书记录（bookUrl / sourceId 等）是目录、正文接口的必要参数，源实例按书名缓存最近一次书架行，缺了再拉。

@module koplugin.book.source.iread
--]]

local Client = require("source.iread.client")
local Mapper = require("source.iread.mapper")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("gettext")

local IRead = {}

---@return BookSourceMeta
function IRead.meta()
    return { id = "iread", name = _("iRead"), type = "chapter" }
end

---@class IReadSource : SourceBase
---@field rows table<string, table>|nil 书名 → 最近一次书架行
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return IReadSource
function IRead.new()
    local meta = IRead.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

---@return boolean
function Source:configured()
    return Client.token() ~= nil
end

---@param rows table[]
---@param stable_id string
---@return table|nil
local function findRow(rows, stable_id)
    for _idx, row in ipairs(rows) do
        if row.name == stable_id then return row end
    end
    return nil
end

--- 拉书架并刷新行缓存。
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Source:fetchShelf(cb)
    return Client.shelfAsync(function(rows, err)
        if not rows then cb(nil, err); return end
        local cache = {}
        for _idx, row in ipairs(rows) do cache[row.name] = row end
        self.rows = cache
        cb(rows)
    end)
end

--- 书架远端：Shelf.syncAsync 要的三个冒号方法。书只能在网站上收藏，本地没有「加入」入口。
local Remote = {}

function Remote:shelfSyncAsync(cb) return self.source:fetchShelf(cb) end

function Remote:addToShelfAsync(_stable_id, cb)
    return SourceBase.defer(cb, nil, _("请在 iRead 网站上收藏书籍"))
end

--- 远端已经没有这本书就算删除完成（收藏接口是开关，不能盲调）。
function Remote:removeFromShelfAsync(stable_id, cb)
    local cancelled, job = false, nil
    job = self.source:fetchShelf(function(rows, err)
        if cancelled then return end
        if not rows then cb(nil, err); return end
        local row = findRow(rows, stable_id)
        if not row then cb(true); return end
        job = Client.removeAsync(row, cb)
    end)
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "iread not logged in") end
    local remote = setmetatable({ source = self }, { __index = Remote })
    return Shelf.syncAsync(self.id, remote, Mapper.shelfList, opts, cb)
end

function Source:syncNotesAsync(_opts, cb)
    return SourceBase.skipped(cb, "iread has no notes")
end

function Source:syncStatsAsync(_opts, cb)
    return SourceBase.skipped(cb, "iread has no stats")
end

--- 取书架行再交给 fn(row)（返回它发起的任务，取消时一并取消）；fresh 为真强制重拉书架
--- （上报进度要覆盖整行，不能用旧行）。
---@param identity BookIdentity
---@param fresh boolean
---@param cb function
---@param fn fun(row: table): { cancel: fun() }|nil
---@return { cancel: fun() }
function Source:withRow(identity, fresh, cb, fn)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录 iRead")) end
    local cached = not fresh and self.rows and self.rows[identity.stable_id]
    if cached then return fn(cached) or SourceBase.defer(function() end) end
    local cancelled, job = false, nil
    job = self:fetchShelf(function(rows, err)
        if cancelled then return end
        if not rows then cb(nil, err); return end
        local row = findRow(rows, identity.stable_id)
        if not row then cb(nil, _("这本书不在 iRead 书架上")); return end
        job = fn(row) or job
    end)
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

function Source:getProgressAsync(identity, cb)
    return self:withRow(identity, true, cb, function(row)
        local read = Mapper.readPos(row)
        if not read then cb(nil, nil, { empty = true }); return nil end
        return self:loadTocAsync(identity, function(toc, reason)
            if not toc then cb(nil, reason); return end
            local idx = math.min(read.index + 1, #toc)
            cb({
                chapter_idx = idx,
                chapter_title = read.title or toc[idx].title,
                fraction = (idx - 1) / #toc,
                extra = { chapter_uid = toc[idx].uid, chapter_idx = idx },
            })
        end)
    end)
end

function Source:putProgressAsync(identity, pos, cb)
    return self:withRow(identity, true, cb, function(row)
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        if not idx then cb(nil, _("缺少阅读章节位置")); return nil end
        local toc = Toc.read(self.id, identity.stable_id)
        local chapter = toc and toc[idx]
        local read = Mapper.readPos(row)
        return Client.saveProgressAsync(row, {
            index = idx - 1,
            title = chapter and chapter.title,
            offset = read and read.index == idx - 1 and read.offset or 0,
        }, cb)
    end)
end

--- 书库里已有的元数据。
function Source:getDetailAsync(identity, cb)
    return SourceBase.defer(cb, identity.book or require("book.books_db").get(self.id, identity.stable_id))
end

function Source:loadTocAsync(identity, cb)
    local cached = Toc.read(self.id, identity.stable_id)
    if cached and #cached > 0 then
        return SourceBase.defer(cb, cached)
    end
    return self:withRow(identity, false, cb, function(row)
        return Client.chaptersAsync(row, function(rows, err)
            if not rows then cb(nil, err); return end
            local toc = Mapper.toc(rows)
            if not Toc.put(self.id, identity.stable_id, toc) then cb(nil, _("章节目录保存失败")); return end
            cb(toc)
        end)
    end)
end

---@return ChapterFetchContent
function Source:contentFetcher()
    return function(identity, chapter, done)
        return self:withRow(identity, false, done, function(row)
            return Client.contentAsync(row, chapter.raw, tonumber(chapter.uid), function(text, err)
                if not text then done(nil, err); return end
                done({ title = chapter.title, html = require("utils.text").chapterHtml(chapter.title, Mapper.text(text)) })
            end)
        end)
    end
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = self:contentFetcher(),
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = self:contentFetcher(),
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    return require("source.chapter").cacheAllAsync(self, identity, self:contentFetcher(), on_progress, cb, 0, range)
end

return IRead
