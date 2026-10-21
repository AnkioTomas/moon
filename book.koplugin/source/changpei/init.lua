--[[--
长佩文学网数据源。

网页 JSON 接口（client.lua）：搜索、目录、免费章正文；登录（setting.lua 粘贴网页 token）后已购 VIP 章可读。没有远端书架 / 进度，
书由书城页搜索后加入本地书库，书库就是唯一真相。没买的 VIP 章开章给临时提示页，目录标「未购」。

@module koplugin.book.source.changpei
--]]

local Client = require("source.changpei.client")
local Mapper = require("source.changpei.mapper")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("gettext")

local Changpei = {}

-- 接口按 IP 限流，预取与整本缓存逐章间隔请求。
local FETCH_INTERVAL = 1

---@return BookSourceMeta
function Changpei.meta()
    return { id = "changpei", name = _("长佩文学"), type = "chapter" }
end

---@class ChangpeiSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return ChangpeiSource
function Changpei.new()
    local meta = Changpei.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

--- 不需要登录，随时可用。
---@return boolean
function Source:configured()
    return true
end

--- 没有远端书架：标删后直接撕墓碑。
---@param identity BookIdentity
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function Source:deleteBookAsync(identity, cb)
    if not require("book.store").markDeleted(self.id, identity.stable_id) then
        return SourceBase.defer(cb, false, _("删除本书失败"))
    end
    if not require("book.books_db").remove(self.id, identity.stable_id) then
        require("utils.log").warn("book changpei tombstone remove failed", identity.stable_id)
    end
    return SourceBase.defer(cb, true)
end

function Source:syncBooksAsync(_opts, cb)
    return SourceBase.skipped(cb, "changpei has no remote")
end

function Source:syncProgressAsync(_opts, cb)
    return SourceBase.skipped(cb, "changpei has no remote")
end

function Source:syncNotesAsync(_opts, cb)
    return SourceBase.skipped(cb, "changpei has no remote")
end

function Source:syncStatsAsync(_opts, cb)
    return SourceBase.skipped(cb, "changpei has no remote")
end

function Source:getProgressAsync(_identity, cb)
    return SourceBase.defer(cb, nil, nil, { empty = true })
end

function Source:putProgressAsync(_identity, _pos, cb)
    return SourceBase.defer(cb, true)
end

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
    if cached and #cached > 0 and cached[1].toc_version == Mapper.TOC_VERSION then
        return SourceBase.defer(cb, cached)
    end
    return Client.chaptersAsync(identity.stable_id, function(wire, err)
        local toc = wire and Mapper.toc(wire)
        if not toc then cb(nil, err); return end
        if #toc == 0 then cb(nil, _("长佩目录为空")); return end
        if not Toc.put(self.id, identity.stable_id, toc) then cb(nil, _("章节目录保存失败")); return end
        cb(toc)
    end)
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = Chapter.vipFetcher(self, Client.contentAsync, true),
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    local Chapter = require("source.chapter")
    return Chapter.prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = Chapter.vipFetcher(self, Client.contentAsync, false),
        interval_seconds = FETCH_INTERVAL,
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    local Chapter = require("source.chapter")
    return Chapter.cacheAllAsync(self, identity, Chapter.vipFetcher(self, Client.contentAsync, false), on_progress, cb,
        FETCH_INTERVAL, range)
end

return Changpei
