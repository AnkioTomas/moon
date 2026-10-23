--[[--
起点中文网数据源。

详情 / 目录 / 章节走手机站页面（client.lua）。登录是浏览器登录态的 Cookie（setting.lua）；
登录后书架双向同步（source.shelf）：拉取、本地加入上行、本地删除上行。
进度只到章：开书从书架行的 readCid 拉，关书经 updReadStatus 推。笔记和统计没有接口。
VIP 章未购买时打开一页临时提示，目录标注已购 / 未购（打开过才知道）。

@module koplugin.book.source.qidian
--]]

require("l10n").apply()
local Browse = require("source.browse")
local Client = require("source.qidian.client")
local Mapper = require("source.qidian.mapper")
local ReviewCache = require("book.review_cache")
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

function Source:syncNotesAsync(_opts, cb)
    return SourceBase.skipped(cb, "qidian has no notes")
end

function Source:syncStatsAsync(_opts, cb)
    return SourceBase.skipped(cb, "qidian has no stats")
end

--- 书架行的 readCid 才是用户看到的进度。getReadStatus 在查询章等于已读章时会把章号省掉。
function Source:getProgressAsync(identity, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录起点")) end
    local cancelled, job = false, nil
    job = Client.shelfAsync(Client.cookie(), function(rows, err)
        if cancelled then return end
        if not rows then cb(nil, err); return end
        local row
        for _idx, item in ipairs(rows) do
            if tostring(item.bid) == tostring(identity.stable_id) then row = item; break end
        end
        local read = Mapper.readChapter(row)
        if not read then cb(nil, nil, { empty = true }); return end
        job = self:loadTocAsync(identity, function(toc, reason)
            if cancelled then return end
            if not toc or #toc == 0 then cb(nil, reason or _("起点目录为空")); return end
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
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录起点")) end
    local cancelled, job = false, nil
    local function send(chapter)
        if not chapter.updated then
            cb(nil, _("起点章节时间缺失"))
            return
        end
        job = Client.updateReadAsync(identity.stable_id, chapter.uid, chapter.title, chapter.vip, chapter.updated,
            function(ok, err)
                if cancelled then return end
                cb(ok and true or nil, err)
            end)
    end
    job = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then cb(nil, err); return end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter or not chapter.uid then
            cb(nil, _("缺少起点章节位置"))
            return
        end
        if chapter.updated then send(chapter); return end
        -- 旧目录缓存没有章节更新时间。不带时间上传会把阅读状态写坏，先补拉目录。
        job = Client.catalogAsync(identity.stable_id, function(data, reason)
            if cancelled then return end
            local fresh = data and Mapper.toc(data)
            if fresh and #fresh > 0 then Toc.put(self.id, identity.stable_id, fresh) end
            local hit
            for _ch, item in ipairs(fresh or {}) do
                if item.uid == chapter.uid then hit = item; break end
            end
            if not hit then cb(nil, reason or _("缺少起点章节位置")); return end
            if not hit.updated then cb(nil, _("起点章节时间缺失")); return end
            send(hit)
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
    return Client.searchAsync(keyword, function(data, err)
        if not data then
            cb(nil, err)
            return
        end
        cb({ data = Mapper.search(data) })
    end)
end

local RANKS = {
    { key = "yuepiao", title = _("月票榜") },
    { key = "hotsales", title = _("畅销榜") },
    { key = "readindex", title = _("阅读指数榜") },
    { key = "newfans", title = _("新人榜") },
    { key = "update", title = _("更新榜") },
    { key = "newbook", title = _("新书榜") },
    { key = "newauthor", title = _("新作者榜") },
}
local CATS = {
    { id = "-1", title = _("全站") }, { id = "21", title = _("玄幻") }, { id = "1", title = _("奇幻") },
    { id = "2", title = _("武侠") }, { id = "22", title = _("仙侠") }, { id = "4", title = _("都市") },
    { id = "15", title = _("现实") }, { id = "6", title = _("军事") }, { id = "5", title = _("历史") },
    { id = "7", title = _("游戏") }, { id = "8", title = _("体育") }, { id = "9", title = _("科幻") },
    { id = "10", title = _("悬疑灵异") }, { id = "20109", title = _("诸天无限") }, { id = "12", title = _("轻小说") },
}

--- 书城浏览：榜单 × 分类两行 chip，节点是「榜单键:分类号」，缺省月票榜全站。榜单页只有一页（20 本）。
---@param opts { node?: string, limit?: integer }
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Source:browseAsync(opts, cb)
    local key, cat = (opts.node or RANKS[1].key .. ":-1"):match("^(%w+):(-?%d+)$")
    local ranks, cats = {}, {}
    for _idx, rank in ipairs(RANKS) do ranks[#ranks + 1] = { id = rank.key .. ":" .. cat, title = rank.title } end
    for _idx, row in ipairs(CATS) do cats[#cats + 1] = { id = key .. ":" .. row.id, title = row.title } end
    local node = key .. ":" .. cat
    local groups = { Browse.group(ranks, node), Browse.group(cats, node) }
    return Client.rankAsync("/rank/" .. key .. "/" .. (cat == "-1" and "" or "catid" .. cat .. "/"), function(data, err)
        if not data then
            cb(nil, err)
            return
        end
        cb({ data = Mapper.rank(data), groups = groups })
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
        if #toc == 0 then cb(nil, _("起点目录为空")); return end
        if not Toc.put(self.id, identity.stable_id, toc) then cb(nil, _("章节目录保存失败")); return end
        cb(toc)
    end)
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
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

--- 阅读页是否显示他人段评（设置页开关，默认关）。
---@return boolean
function Source:paragraphReviewsEnabled()
    return require("source.review_setting").enabled(self.id)
end

--- 章节序号 → 起点章号，目录来自缓存或在线拉取；start 返回要取消的任务。
---@param self QidianSource
---@param identity BookIdentity
---@param cb fun(value: any, err: string|nil)
---@param start fun(chapter_id: string, finish: function): { cancel: fun() }|nil
---@return { cancel: fun() }
local function withChapterId(self, identity, cb, start)
    local cancelled, job = false, nil
    job = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        local chapter = toc and toc[tonumber(identity.chapter_idx)]
        if not chapter then
            cb(nil, err or _("缺少起点章节位置"))
            return
        end
        job = start(chapter.uid, cb)
    end)
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

--- 本章有评论的段落（未定位）。
---@param identity BookIdentity
---@param cb fun(hotspots: QidianReviewHotspot[]|nil, err: string|nil)
---@return { cancel: fun() }
function Source:paragraphHotspotsAsync(identity, cb)
    return ReviewCache.hotspotsAsync(identity, function(done)
        return withChapterId(self, identity, done, function(uid, finish)
            return require("source.qidian.reviews").hotspotsAsync(identity.stable_id, uid, finish)
        end)
    end, cb)
end

--- 段落按段序定位到章节 HTML（子进程里跑，不碰实例状态）。
---@param hotspots QidianReviewHotspot[]
---@param html string
---@return table[]
function Source:locateHotspots(hotspots, html)
    return require("source.qidian.reviews").locate(hotspots, html)
end

--- 某段的一页评论；range 是段落序号，max_idx 是已取页数（首页 0）。
---@param identity BookIdentity
---@param range string
---@param max_idx integer
---@param cb fun(page: WechatReviewPage|nil, err: string|nil)
---@return { cancel: fun() }
function Source:paragraphReviewPageAsync(identity, range, max_idx, cb)
    return ReviewCache.pageAsync(identity, range, max_idx, function(done)
        return withChapterId(self, identity, done, function(uid, finish)
            return require("source.qidian.reviews").pageAsync(identity.stable_id, uid, tonumber(range), max_idx, finish)
        end)
    end, cb)
end

return Qidian
