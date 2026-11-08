--[[--
QQ阅读数据源。

目录 / 章节走 book.qq.com 的 JSON 接口（client.lua）。登录是浏览器登录态的 Cookie（setting.lua）；
登录后书架双向同步（source.shelf）：拉取、本地加入上行、本地删除上行。
进度只到章：开书从详情的 lastReadChapterId 拉，关书经 update/reading/process 推。书不在书架上不推，也不加回去。
笔记和统计没有接口。付费章未授权时打开一页临时提示，目录标注已购 / 未购（打开过才知道）。

@module koplugin.book.source.qqreader
--]]

local Browse = require("source.browse")
local Client = require("source.qqreader.client")
local Mapper = require("source.qqreader.mapper")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("l10n").get("source.qqreader")

local QQReader = {}

-- 章节不小，预取与整本缓存逐章间隔请求。
local FETCH_INTERVAL = 1

---@return BookSourceMeta
function QQReader.meta()
    return SourceBase.loadMeta("qqreader")
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
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
local function fillDetails(rows, cb)
    local BookDB = require("book.books_db")
    local cancelled, job, index, cookie = false, nil, 0, Client.cookie()
    local function nextRow()
        if cancelled then return end
        if Client.cookie() ~= cookie then cb(nil, _("账号已变化，请重新登录")); return end
        index = index + 1
        local row = rows[index]
        if not row then cb(rows); return end
        row.local_book = BookDB.get(QQReader.meta().id, tostring(row.bid))
        local intro = row.local_book and row.local_book.intro
        if intro and intro ~= "" then nextRow(); return end
        local pending = true
        local inner = Client.detailAsync(row.bid, function(info, err)
            pending = false
            if cancelled then return end
            if Client.cookie() ~= cookie then cb(nil, _("账号已变化，请重新登录")); return end
            if info then
                row.info = info
            else
                require("utils.log").warn("book qqreader detail failed", row.bid, err)
            end
            nextRow()
        end)
        if pending then job = inner end
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
    local cancelled, job, fill, cookie = false, nil, nil, Client.cookie()
    job = Client.shelfAsync(cookie, function(rows, err)
        if cancelled then return end
        if Client.cookie() ~= cookie then cb(nil, _("账号已变化，请重新登录")); return end
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

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "qqreader not logged in") end
    return Shelf.syncAsync(self.id, Remote, Mapper.shelfList, opts, cb)
end

--- 详情上的 lastReadChapterId 就是书架行那一章。0 是没读过。
function Source:getProgressAsync(identity, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录 QQ阅读")) end
    local cancelled, job, cookie = false, nil, Client.cookie()
    local pending = true
    local inner = Client.detailAsync(identity.stable_id, function(info, err)
        pending = false
        if cancelled then return end
        if Client.cookie() ~= cookie then cb(nil, _("账号已变化，请重新登录")); return end
        if not info then cb(nil, err); return end
        local read = Mapper.readChapter(info)
        if not read then cb(nil, nil, { empty = true }); return end
        job = self:loadTocAsync(identity, function(toc, reason)
            if cancelled then return end
            if Client.cookie() ~= cookie then cb(nil, _("账号已变化，请重新登录")); return end
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
    if pending then job = inner end
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

function Source:putProgressAsync(identity, pos, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录 QQ阅读")) end
    local cancelled, job = false, nil
    local cookie = Client.cookie()
    local pending = true
    local inner = self:loadTocAsync(identity, function(toc, err)
        pending = false
        if cancelled then return end
        if Client.cookie() ~= cookie then cb(nil, _("账号已变化，请重新登录")); return end
        if not toc then cb(nil, err); return end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter or not chapter.uid then
            cb(nil, _("缺少 QQ阅读章节位置"))
            return
        end
        local checking = true
        local detail = Client.detailAsync(identity.stable_id, function(info, reason)
            checking = false
            if cancelled then return end
            if Client.cookie() ~= cookie then cb(nil, _("账号已变化，请重新登录")); return end
            if not info then cb(nil, reason); return end
            if not Mapper.onShelf(info) then cb(nil, _("这本书不在 QQ阅读书架上")); return end
            job = Client.updateReadAsync(identity.stable_id, chapter.uid, function(ok, push_err)
                if cancelled then return end
                if Client.cookie() ~= cookie then cb(nil, _("账号已变化，请重新登录")); return end
                cb(ok and true or nil, push_err)
            end)
        end)
        if checking then job = detail end
    end)
    if pending then job = inner end
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
    return Browse.pages(function(page, done) return Client.searchAsync(keyword, done, page) end, 200, {}, cb)
end

local RANKS = {
    { id = "rank:male-sell", title = _("男生热门榜") }, { id = "rank:male-new", title = _("男生新书榜") },
    { id = "rank:male-free", title = _("男生免费榜") }, { id = "rank:male-finish", title = _("男生完结榜") },
    { id = "rank:male-god", title = _("男生封神榜") }, { id = "rank:female-sell", title = _("女生热门榜") },
    { id = "rank:female-new", title = _("女生新书榜") }, { id = "rank:female-free", title = _("女生免费榜") },
    { id = "rank:female-finish", title = _("女生完结榜") }, { id = "rank:female-god", title = _("女生封神榜") },
    { id = "rank:publish-sell", title = _("出版热门榜") }, { id = "rank:publish-new", title = _("出版新书榜") },
    { id = "rank:publish-knowledge", title = _("出版新知榜") },
}
--- 缺省仍为男生热门榜；分类沿用旧 cate:分类号，并支持官网八段筛选节点。
---@param opts { node?: string, limit?: integer }
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Source:browseAsync(opts, cb)
    local node = opts.node or RANKS[1].id
    local kind, name = node:match("^(%a+):(.+)$")
    if kind == "cate" then return require("source.qqreader.browse").run(opts, cb) end
    local known = false
    for _idx, rank in ipairs(RANKS) do if rank.id == node then known = true; break end end
    if not known then return SourceBase.defer(cb, nil, _("QQ阅读分类条件无效")) end
    local ranks = Browse.group(RANKS, node)
    ranks.title = _("排行榜")
    local groups = { ranks, Browse.group({ { id = "cate:0", title = _("分类") } }, node) }
    return Browse.pages(function(page, done)
        local path = "/book-rank/" .. name .. "/cycle-1" .. (page > 1 and "-" .. page or "")
        return Client.listAsync(path, done)
    end, opts.limit or 60, groups, cb)
end

--- 这是整书书评。官网可能只返回十五条且不给下一页游标，不能冒充完整书评。
function Source:bookReviewsAsync(identity, cb)
    return Client.bookCommentsAsync(identity.stable_id, function(data, err)
        if not data then cb(nil, err); return end
        local items = Mapper.bookComments(data.comments)
        local total = tonumber(data.commentCount)
        cb({
            title = #items < total and require("ffi/util").template(_("书评（预览 %1/%2）"), #items, total) or _("书评"),
            items = items,
            total = total,
            more = #items < total,
        })
    end)
end

function Source:getDetailAsync(identity, cb)
    return SourceBase.defer(cb, identity.book or require("book.books_db").get(self.id, identity.stable_id))
end

--- 强制拉目录并写回；失败由调用方继续用旧缓存。
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }
local function fetchTocAsync(self, identity, cb)
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

return QQReader
