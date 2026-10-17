--[[--
七猫免费小说数据源。

搜索 / 目录 / 正文走匿名 App 接口（protocol / client，正文解密，按章落盘走公共 source/chapter）；
登录是 PC 网页的 token（setting.lua），登录后书架双向同步（source.shelf，网页书架接口）。
网页没有进度 / 笔记 / 统计接口：这三个域只在本地。书由书城页（store/qimao）搜索后加入本地书库。

@module koplugin.book.source.qimao
--]]

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

function Source:syncProgressAsync(_opts, cb)
    return SourceBase.skipped(cb, "qimao has no remote")
end

function Source:syncNotesAsync(_opts, cb)
    return SourceBase.skipped(cb, "qimao has no remote")
end

function Source:syncStatsAsync(_opts, cb)
    return SourceBase.skipped(cb, "qimao has no remote")
end

function Source:getProgressAsync(_identity, cb)
    return SourceBase.defer(cb, nil, nil, { empty = true })
end

function Source:putProgressAsync(_identity, _pos, cb)
    return SourceBase.defer(cb, true)
end

--- 书库里已有的元数据；七猫详情只在书城预览时才需要拉（见 store/qimao）。
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
            done({ title = chapter.title, text = text })
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
