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
local Protocols = require("source.jjwxc.protocols")
local ReviewCache = require("book.review_cache")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local Web = require("source.jjwxc.protocols.web")
local _ = require("gettext")

local Jjwxc = {}

-- 接口按 IP 限流，预取与整本缓存逐章间隔请求。
local FETCH_INTERVAL = 1

---@return BookSourceMeta
function Jjwxc.meta()
    return SourceBase.loadMeta("jjwxc")
end

---@class JjwxcSource : SourceBase
---@field probe { stable_id: string, cancel: fun() }|nil 在飞的 VIP 章购买状态探测
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return JjwxcSource
function Jjwxc.new()
    local meta = Jjwxc.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

---@return boolean
function Source:configured()
    return Protocols.current() ~= nil
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
        local pending = true
        local initial = Client.detailAsync(row.id, function(info, err)
            pending = false
            if cancelled then return end
            if info then
                row.info = info
            else
                require("utils.log").warn("book jjwxc detail failed", row.id, err)
            end
            nextRow()
        end)
        if pending then job = initial end
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
    job = Protocols.current().shelfAsync(function(rows, err)
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
    if Protocols.current() ~= Web then
        return SourceBase.defer(cb, nil, _("App 协议暂不支持取消收藏，请在设置里改用网页协议"))
    end
    return Web.favRemoveAsync(stable_id, cb)
end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "jjwxc not logged in") end
    return Shelf.syncAsync(self.id, Remote, Mapper.shelfList, opts, cb)
end

--- 进度 / 笔记 / 统计没有远端接口：不定义 put/push 方法，基类按能力回 skipped，脏行不入推送队列。

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

--- 书城浏览：默认官网分类库；兼容「榜单序号:频道序号」旧节点。
--- 榜单名和频道来自书城首页；书按页拉到 opts.limit。
---@param opts { node?: string, limit?: integer }
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Source:browseAsync(opts, cb)
    opts = opts or {}
    if not opts.node or opts.node:sub(1, 5) == "cate:" then
        return require("source.jjwxc.browse").run(opts, cb)
    end
    local handle = {}
    -- 首页缓存命中时回调是下一拍，不会在赋值前跑完；这里仍按同步回调记步，避免把已换上的翻页句柄盖掉。
    local step = 0
    local function load(ranks)
        if handle.cancelled then return end
        step = step + 1
        if #ranks == 0 then cb(nil, _("晋江榜单无法解析")); return end
        local rank_s, ch_s = (opts.node or "1:1"):match("^(%d+):(%d+)$")
        local rank_i = tonumber(rank_s) or 1
        if not ranks[rank_i] then rank_i = 1 end
        local channels = ranks[rank_i].channels
        local ch_i = tonumber(ch_s) or 1
        if not channels[ch_i] then ch_i = 1 end
        local node = rank_i .. ":" .. ch_i
        local rank_chips, channel_chips = {}, {}
        for i, rank in ipairs(ranks) do
            local ci = rank.channels[ch_i] and ch_i or 1
            rank_chips[#rank_chips + 1] = { id = i .. ":" .. ci, title = rank.title }
        end
        for i, ch in ipairs(channels) do
            channel_chips[#channel_chips + 1] = { id = rank_i .. ":" .. i, title = ch.title }
        end
        local page_size = Client.RANK_PAGE
        handle.inner = Browse.pages(function(page, done)
            return Client.rankPageAsync(channels[ch_i].id, (page - 1) * page_size, function(wire, err)
                if not wire then done(nil, err); return end
                local books = Mapper.rankBooks(wire)
                done(books, nil, #books >= page_size)
            end)
        end, opts.limit or 60, { Browse.group(rank_chips, node), Browse.group(channel_chips, node),
            { title = _("分类书库"), chips = { { id = "cate:0:0:0:0:0:0:2", title = _("分类书库") } } } }, cb)
    end
    local first = Client.storeHomeAsync(function(wire, err)
        if handle.cancelled then return end
        if not wire then cb(nil, err); return end
        load(Mapper.storeRanks(wire))
    end)
    if step == 0 then handle.inner = first end
    function handle.cancel()
        handle.cancelled = true
        if handle.inner then handle.inner:cancel() end
    end
    return handle
end

function Source:getDetailAsync(identity, cb)
    return SourceBase.defer(cb, identity.book or require("book.books_db").get(self.id, identity.stable_id))
end

--- 目录里还没问过的 VIP 章逐章问一遍购买状态（只在已登录时），问完落库一次；失败（断网 / Cookie 失效）就停。
--- 一个源实例同时只有一条探测（`self.probe`）：同一本书在飞就不重开；换书则取消旧的。
--- 探测拿着自己那份目录表，结束时整表写回，所以目录重拉前必须先取消它，否则旧表把新目录盖回去。
---@param self JjwxcSource
---@param identity BookIdentity
---@param toc BookChapter[]
local function probePaid(self, identity, toc)
    if Protocols.current() ~= Web then return end
    local todo = {}
    for _idx, chapter in ipairs(toc) do
        if chapter.vip and chapter.paid == nil then todo[#todo + 1] = chapter end
    end
    if #todo == 0 then return end
    if self.probe then
        if self.probe.stable_id == identity.stable_id then return end
        self.probe.cancel()
    end
    local pos, changed, cancelled, job = 0, false, false, nil
    local probe = { stable_id = identity.stable_id }
    probe.cancel = function()
        cancelled = true
        if job then job.cancel() end
        if self.probe == probe then self.probe = nil end
    end
    local function nextChapter()
        pos = pos + 1
        local chapter = todo[pos]
        if not chapter then
            self.probe = nil
            if changed then Toc.put(self.id, identity.stable_id, toc) end
            return
        end
        local pending = true
        local initial = Web.paidAsync(identity.stable_id, chapter.uid, function(paid)
            pending = false
            if cancelled then return end
            if paid == nil then
                pos = #todo
            else
                chapter.paid, changed = paid, true
            end
            nextChapter()
        end)
        if pending then job = initial end
    end
    self.probe = probe
    nextChapter()
end

function Source:close()
    if self.probe then self.probe.cancel() end
end

--- 强制拉目录并写回；失败由调用方继续用旧缓存。
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }
local function fetchTocAsync(self, identity, cb)
    local cancelled, job = false, nil
    job = Client.chaptersAsync(identity.stable_id, function(wire, err)
        if cancelled then return end
        local toc = wire and Mapper.toc(wire)
        if not toc then cb(nil, err); return end
        if #toc == 0 then cb(nil, _("晋江目录为空")); return end
        if self.probe and self.probe.stable_id == identity.stable_id then self.probe.cancel() end
        if not Toc.put(self.id, identity.stable_id, toc) then cb(nil, _("章节目录保存失败")); return end
        cb(toc)
        probePaid(self, identity, toc)
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
        if cached and #cached > 0 and cached[1].toc_version == Mapper.TOC_VERSION then
            probePaid(self, identity, cached)
            return SourceBase.defer(cb, cached)
        end
    end
    return fetchTocAsync(self, identity, cb)
end

Source.refreshTocAsync = fetchTocAsync

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local locate = require("book.review_locate")
    local reviews = self:paragraphReviewsEnabled()
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = Chapter.vipFetcher(self, Client.contentAsync, true, reviews and locate.prepareChapterEnd or nil),
        reuse = reviews and locate.reuseChapterEnd or nil,
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    local Chapter = require("source.chapter")
    local locate = require("book.review_locate")
    local reviews = self:paragraphReviewsEnabled()
    return Chapter.prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = Chapter.vipFetcher(self, Client.contentAsync, false, reviews and locate.prepareChapterEnd or nil),
        reuse = reviews and locate.reuseChapterEnd or nil,
        interval_seconds = FETCH_INTERVAL,
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    local Chapter = require("source.chapter")
    local prepare = self:paragraphReviewsEnabled() and require("book.review_locate").prepareChapterEnd or nil
    return Chapter.cacheAllAsync(self, identity, Chapter.vipFetcher(self, Client.contentAsync, false, prepare), on_progress, cb,
        FETCH_INTERVAL, range)
end

--- 阅读页是否显示他人段评（设置页开关，默认关）。
---@return boolean
function Source:paragraphReviewsEnabled()
    return require("source.review_setting").enabled(self.id)
end

--- 本章有评论的段落（未定位）。
---@param identity BookIdentity
---@param cb fun(hotspots: JjwxcReviewHotspot[]|nil, err: string|nil)
---@return { cancel: fun() }
local function hotspotsAsync(self, identity, cb)
    local withUid = require("source.with_chapter_uid")
    return ReviewCache.hotspotsAsync(identity, function(done)
        return withUid.run(self, identity, _("缺少晋江章节位置"), function(uid, finish)
            return require("source.jjwxc.reviews").hotspotsAsync(identity.stable_id, uid, finish)
        end, done)
    end, cb)
end

function Source:paragraphHotspotsAsync(identity, cb)
    return hotspotsAsync(self, identity, function(list, err)
        if not list then cb(nil, err); return end
        local paragraphs = {}
        for _idx, spot in ipairs(list) do
            if tonumber(spot.range) > 0 then paragraphs[#paragraphs + 1] = spot end
        end
        cb(paragraphs)
    end)
end

function Source:chapterReviewHotspotsAsync(identity, cb)
    return hotspotsAsync(self, identity, function(list, err)
        if not list then cb(nil, err); return end
        local ending = {}
        for _idx, spot in ipairs(list) do
            if spot.range == "-2" then
                ending[#ending + 1] = { range = spot.range, text = _("本章讨论"), total = spot.total,
                    badge = tostring(spot.total), heading = _("章节评论"),
                    anchor = require("book.review_locate").CHAPTER_ANCHOR }
            end
        end
        cb(ending)
    end)
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
    local withUid = require("source.with_chapter_uid")
    local Reviews = require("source.jjwxc.reviews")
    local Text = require("utils.text")
    return ReviewCache.pageAsync(identity, range, max_idx, function(done)
        return withUid.run(self, identity, _("缺少晋江章节位置"), function(uid, finish)
            return Reviews.pageAsync(identity.stable_id, uid, tonumber(range), max_idx, finish)
        end, done)
    end, function(page, err)
        if page then
            for _idx, item in ipairs(page.items) do
                item.content = Text.stripHtml(item.content)
                if not item.inline_images then item.inline_images = Reviews.inlineImages(item.content) end
            end
        end
        cb(page, err)
    end)
end

return Jjwxc
