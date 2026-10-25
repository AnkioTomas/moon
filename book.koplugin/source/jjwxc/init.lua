--[[--
晋江文学城数据源。

书的元数据 / 目录 / 免费章正文走匿名 App 接口，VIP 章与个人收藏走手机网页 Cookie（client.lua）。
登录是浏览器登录态的 Cookie（setting.lua）；登录后收藏双向同步（source.shelf）：拉取、本地删除上行。
段评走网页版匿名接口（reviews.lua），设置里开关。
最近阅读页能读到章，但没有确认能写回的接口，进度不接，避免只拉不推。笔记和统计没有接口。

@module koplugin.book.source.jjwxc
--]]

local Browse = require("source.browse")
local Client = require("source.jjwxc.client")
local Mapper = require("source.jjwxc.mapper")
local ReviewCache = require("book.review_cache")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("gettext")

local Jjwxc = {}

-- 接口按 IP 限流，预取与整本缓存逐章间隔请求。
local FETCH_INTERVAL = 1

---@return BookSourceMeta
function Jjwxc.meta()
    return require("source.meta").get("jjwxc")
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
    return Client.cookie() ~= nil or Client.token() ~= nil
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
    local cookie = Client.cookie()
    local fetch = cookie and function(done) return Client.favAsync(cookie, done) end
        or function(done) return Client.tokenFavAsync(Client.token(), done) end
    job = fetch(function(rows, err)
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
    if not Client.cookie() then
        return SourceBase.defer(cb, nil, _("账号密码登录暂不支持取消收藏，请用浏览器登录"))
    end
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

local RANKS = {
    { "5", _("月度榜") }, { "6", _("季度榜") }, { "30", _("半年榜") }, { "58", _("完结金榜") },
    { "64", _("总分榜") }, { "42", _("霸王票总榜") }, { "44", _("读者栽培榜") },
}

--- 书城浏览：榜单 / 频道两行 chip，节点是「榜单号:频道序号」，缺省月度榜第一个频道。
--- 榜单页一次给齐各频道各 20 本，频道 chip 由页面解析得出；这里的书只有书名和书号。
---@param opts { node?: string, limit?: integer }
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Source:browseAsync(opts, cb)
    local rank, idx = (opts.node or RANKS[1][1] .. ":1"):match("^(%d+):(%d+)$")
    return Client.rankAsync(rank, function(sections, err)
        if not sections then
            cb(nil, err)
            return
        end
        local ranks, channels = {}, {}
        for _idx, row in ipairs(RANKS) do ranks[#ranks + 1] = { id = row[1] .. ":" .. idx, title = row[2] } end
        for i, section in ipairs(sections) do
            channels[#channels + 1] = { id = rank .. ":" .. i, title = (section.title:gsub("排行$", "")) }
        end
        local node = rank .. ":" .. idx
        local section = sections[tonumber(idx)] or sections[1]
        cb({ data = section.books, groups = { Browse.group(ranks, node), Browse.group(channels, node) } })
    end)
end

function Source:getDetailAsync(identity, cb)
    return SourceBase.defer(cb, identity.book or require("book.books_db").get(self.id, identity.stable_id))
end

--- 目录里还没问过的 VIP 章逐章问一遍购买状态（只在已登录时），问完落库一次；失败（断网 / Cookie 失效）就停。
---@param self BookSource
---@param identity BookIdentity
---@param toc BookChapter[]
local function probePaid(self, identity, toc)
    if not Client.cookie() or self.probing then return end
    local todo = {}
    for _idx, chapter in ipairs(toc) do
        if chapter.vip and chapter.paid == nil then todo[#todo + 1] = chapter end
    end
    if #todo == 0 then return end
    self.probing = true
    local pos, changed = 0, false
    local function nextChapter()
        pos = pos + 1
        local chapter = todo[pos]
        if not chapter then
            self.probing = nil
            if changed then Toc.put(self.id, identity.stable_id, toc) end
            return
        end
        Client.paidAsync(identity.stable_id, chapter.uid, function(paid)
            if paid == nil then
                pos = #todo
            else
                chapter.paid, changed = paid, true
            end
            nextChapter()
        end)
    end
    nextChapter()
end

function Source:loadTocAsync(identity, cb)
    local cached = Toc.read(self.id, identity.stable_id)
    if cached and #cached > 0 and cached[1].toc_version == Mapper.TOC_VERSION then
        probePaid(self, identity, cached)
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
        probePaid(self, identity, toc)
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

--- 章节序号 → 晋江章号，目录来自缓存或在线拉取；start 返回要取消的任务。
---@param self JjwxcSource
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
            cb(nil, err or _("缺少晋江章节位置"))
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
---@param cb fun(hotspots: JjwxcReviewHotspot[]|nil, err: string|nil)
---@return { cancel: fun() }
function Source:paragraphHotspotsAsync(identity, cb)
    return ReviewCache.hotspotsAsync(identity, function(done)
        return withChapterId(self, identity, done, function(uid, finish)
            return require("source.jjwxc.reviews").hotspotsAsync(identity.stable_id, uid, finish)
        end)
    end, cb)
end

--- 段落按段末文字定位到章节 HTML（子进程里跑，不碰实例状态）。
---@param hotspots JjwxcReviewHotspot[]
---@param html string
---@return table[]
function Source:locateHotspots(hotspots, html)
    return require("source.jjwxc.reviews").locate(hotspots, html)
end

--- 某段的一页评论；range 是段落序号，max_idx 是翻页偏移（首页 0）。
---@param identity BookIdentity
---@param range string
---@param max_idx integer
---@param cb fun(page: WechatReviewPage|nil, err: string|nil)
---@return { cancel: fun() }
function Source:paragraphReviewPageAsync(identity, range, max_idx, cb)
    return ReviewCache.pageAsync(identity, range, max_idx, function(done)
        return withChapterId(self, identity, done, function(uid, finish)
            return require("source.jjwxc.reviews").pageAsync(identity.stable_id, uid, tonumber(range), max_idx, finish)
        end)
    end, cb)
end

return Jjwxc
