--[[--
得到数据源。

扫码登录后同步已购电子书。目录和正文要阅读 token，正文是网页同款加密 SVG。

@module koplugin.book.source.dedao
--]]

require("l10n").apply()
local Client = require("source.dedao.client")
local Mapper = require("source.dedao.mapper")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local Text = require("utils.text")
local _ = require("gettext")

local Dedao = {}

---@return BookSourceMeta
function Dedao.meta()
    return SourceBase.loadMeta("dedao")
end

---@class DedaoSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return DedaoSource
function Dedao.new()
    local meta = Dedao.meta()
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
function Remote:addToShelfAsync(stable_id, cb) return Client.addAsync(stable_id, cb) end

---@param stable_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
function Remote:removeFromShelfAsync(stable_id, cb) return Client.removeAsync(stable_id, cb) end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "dedao not logged in") end
    return Shelf.syncAsync(self.id, Remote, Mapper.shelf, opts, cb)
end

---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
function Source:searchAsync(keyword, cb)
    return Client.searchAsync(keyword, function(body, err)
        if not body then cb(nil, err or _("请求失败")); return end
        cb({ data = Mapper.search(body) })
    end)
end

function Source:getDetailAsync(identity, cb)
    return Client.detailAsync(identity.stable_id, function(body, err)
        local detail = Mapper.detail(body, identity.stable_id)
        if detail then cb(require("book.store").rememberDetail(detail)); return end
        local row = identity.book or require("book.books_db").get(self.id, identity.stable_id)
        if row then cb(row); return end
        cb(nil, err or _("请求失败"))
    end)
end

---@param self DedaoSource
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
local function fetchTocAsync(self, identity, cb)
    return Client.bookInfoAsync(identity.stable_id, function(info, err)
        if not info then cb(nil, err); return end
        local toc = Mapper.chapters(info)
        if #toc == 0 then cb(nil, _("得到目录为空")); return end
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

---@param open boolean
---@return ChapterFetchContent
local function fetcher(open)
    return function(identity, chapter, done)
        return Client.contentAsync(identity.stable_id, chapter.uid, function(text, err, kind)
            if text and not err then
                done({ title = chapter.title, html = text })
            elseif open and kind == "unpaid" then
                local notice = string.format(_("这是 VIP 章节，你还没有购买。\n请先在%s购买本章，再回来阅读。"), _("得到"))
                done({
                    title = chapter.title,
                    html = Text.chapterHtml(chapter.title, notice),
                    temporary = true,
                })
            else
                done(nil, err)
            end
        end)
    end
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = fetcher(true),
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    local Chapter = require("source.chapter")
    return Chapter.prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = fetcher(false),
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    local Chapter = require("source.chapter")
    return Chapter.cacheAllAsync(self, identity, fetcher(false), on_progress, cb, nil, range)
end

function Source:getProgressAsync(identity, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录得到")) end
    local cancelled, job = false, nil
    job = Client.progressAsync(identity.stable_id, function(item, err)
        if cancelled then return end
        if err then cb(nil, err); return end
        local uid = type(item) == "table" and Mapper.progressUid(item.findex) or nil
        if not uid then cb(nil, nil, { empty = true }); return end
        job = self:loadTocAsync(identity, function(toc, reason)
            if cancelled then return end
            if not toc or #toc == 0 then cb(nil, reason or _("得到目录为空")); return end
            local idx = Toc.index(self.id, identity.stable_id, uid)
            if not idx then cb(nil, nil, { empty = true }); return end
            local fraction = (idx - 1) / #toc
            cb({
                chapter_idx = idx,
                chapter_title = toc[idx].title,
                fraction = fraction,
                extra = { chapter_uid = uid, chapter_idx = idx },
            })
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

function Source:putProgressAsync(identity, pos, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录得到")) end
    local cancelled, job = false, nil
    job = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then cb(nil, err); return end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter then cb(nil, _("缺少得到章节位置")); return end
        job = Client.putProgressAsync(identity.stable_id, chapter.uid, chapter.title, function(ok, perr)
            cb(ok and true or nil, perr)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

return Dedao
