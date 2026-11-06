--[[--
掌阅数据源。

扫码登录（掌阅 App）后，书架、目录、正文、进度走 PC 站 JSON。
书城搜索和频道走手机站页面。网页没有移出书架接口，本地删除只留墓碑。

@module koplugin.book.source.ireader
--]]

require("l10n").apply()
local Browse = require("source.browse")
local Client = require("source.ireader.client")
local Mapper = require("source.ireader.mapper")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local Text = require("utils.text")
local _ = require("gettext")

local IReader = {}

local FETCH_INTERVAL = 0.5

local CHANNELS = {
    { id = "h5_ch_male", title = "男生" },
    { id = "h5_ch_female", title = "女生" },
    { id = "h5_ch_publish", title = "出版" },
}

---@return BookSourceMeta
function IReader.meta()
    return SourceBase.loadMeta("ireader")
end

---@class IReaderSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return IReaderSource
function IReader.new()
    local meta = IReader.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

---@return boolean
function Source:configured()
    return Client.session() ~= nil
end

local Remote = {}

function Remote:shelfSyncAsync(cb) return Client.shelfAsync(cb) end

---@param stable_id string
---@param cb fun(ok: boolean|nil, err: string|nil)
function Remote:addToShelfAsync(stable_id, cb)
    local row = require("book.books_db").get("ireader", stable_id)
    return Client.addAsync(stable_id, row and row.title or stable_id, cb)
end

--- 掌阅 PC 站没有移出书架的请求。返回失败，墓碑留着，下次拉书架也不会把这本书加回来。
function Remote:removeFromShelfAsync(_stable_id, cb)
    return SourceBase.defer(cb, nil, _("掌阅网页不能把书移出书架"))
end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "ireader not logged in") end
    return Shelf.syncAsync(self.id, Remote, Mapper.shelf, opts, cb)
end

---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
function Source:searchAsync(keyword, cb)
    return Client.searchAsync(keyword, function(html, err)
        if not html then cb(nil, err or _("请求失败")); return end
        cb({ data = Mapper.search(html) })
    end)
end

---@param opts { node?: string }|nil
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
function Source:browseAsync(opts, cb)
    local node = opts and opts.node or CHANNELS[1].id
    local known = false
    local chips = {}
    for _idx, channel in ipairs(CHANNELS) do
        chips[#chips + 1] = { id = channel.id, title = _(channel.title) }
        if channel.id == node then known = true end
    end
    if not known then node = CHANNELS[1].id end
    return Client.channelAsync(node, function(html, err)
        if not html then cb(nil, err or _("请求失败")); return end
        cb({ data = Mapper.channel(html), groups = { Browse.group(chips, node) } })
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

---@param self IReaderSource
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
local function fetchTocAsync(self, identity, cb)
    return Client.chaptersAsync(identity.stable_id, function(rows, err)
        if not rows then cb(nil, err); return end
        local toc = Mapper.chapters(rows)
        if #toc == 0 then cb(nil, _("掌阅目录为空")); return end
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
        return Client.contentAsync(identity.stable_id, chapter.uid, function(html, err, kind)
            if html then
                done({ title = chapter.title, html = html })
            elseif open and kind == "unpaid" then
                local notice = string.format(_("这是 VIP 章节，你还没有购买。\n请先在%s购买本章，再回来阅读。"), _("掌阅"))
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
        interval_seconds = FETCH_INTERVAL,
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    local Chapter = require("source.chapter")
    return Chapter.cacheAllAsync(self, identity, fetcher(false), on_progress, cb, FETCH_INTERVAL, range)
end

function Source:getProgressAsync(identity, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录掌阅")) end
    local cancelled, job = false, nil
    job = Client.progressAsync(identity.stable_id, function(item, err)
        if cancelled then return end
        if err then cb(nil, err); return end
        ---@type { chapterId: string|number|nil, readPercent: string|number|nil }|nil
        local process = type(item) == "table" and item.readProcess or nil
        local uid = type(process) == "table" and Mapper.progressUid(process.chapterId) or nil
        if not uid then cb(nil, nil, { empty = true }); return end
        job = self:loadTocAsync(identity, function(toc, reason)
            if cancelled then return end
            if not toc or #toc == 0 then cb(nil, reason or _("掌阅目录为空")); return end
            local idx = Toc.index(self.id, identity.stable_id, uid)
            if not idx then cb(nil, nil, { empty = true }); return end
            local percent = tonumber(process.readPercent)
            local fraction = percent and percent > 1 and percent / 100 or (idx - 1) / #toc
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
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录掌阅")) end
    local cancelled, job = false, nil
    job = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then cb(nil, err); return end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter then cb(nil, _("缺少掌阅章节位置")); return end
        job = Client.putProgressAsync(identity.stable_id, chapter.uid, #toc, function(ok, perr)
            cb(ok and true or nil, perr)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

return IReader
