--[[--
番茄小说官方数据源。

正文走 App reading API：registerkey → batch_full → 解密（reading/）。书架双向（加架 / 移出架经番茄网页接口，Shelf.syncAsync 编排），搜索走免登录端点，进度双向，无笔记、统计。
封面用 fanqie.lua 的 mobileCover 稳定路径（网页签名 thumb_url 会过期）。19 位设备 id 按 uint64 精确编码；Cookie 没变不重写设置。

@module koplugin.book.source.fanqie
--]]

local Base = require("source.base")
local Browse = require("source.browse")
local Assets = require("source.assets")
local Cbz = require("source.cbz")
local Comic = require("source.fanqie.comic")
local Paths = require("utils.paths")
local ReviewCache = require("book.review_cache")
require("l10n").apply()
local _ = require("gettext")
local T = require("ffi/util").template

local M = {}

---@class FanqieSource : SourceBase
---@field settings FanqieSettings
---@field client FanqieClient

local Source = setmetatable({}, { __index = Base })
Source.__index = Source

function M.meta()
    return { id = "fanqie", name = _("番茄小说"), type = "chapter" }
end

function M.new()
    local Settings = require("source.fanqie.settings")
    local Client = require("source.fanqie.client")
    local settings = Settings:new()
    local meta = M.meta()
    return setmetatable({
        id = meta.id,
        name = meta.name,
        type = meta.type,
        settings = settings,
        client = Client:new(settings),
    }, Source)
end

function Source:configured()
    return self.settings:is_cookie_configured()
end

---@class FanqieAsyncHandle : CancelHandle
---@field job CancelHandle|nil
---@field cancelled boolean

---@return FanqieAsyncHandle
local function handle()
    ---@type FanqieAsyncHandle
    local h
    h = {
        job = nil,
        cancelled = false,
        cancel = function()
            h.cancelled = true
            if h.job and h.job.cancel then
                h.job.cancel()
            end
        end,
    }
    return h
end

---@return string
local function errMsg(err)
    if type(err) == "table" then
        return tostring(err.message or err.err or _("番茄请求失败"))
    end
    return tostring(err or _("番茄请求失败"))
end

---@param wire table fetchShelfDetailAsync 的回包
---@return Book[]
local function shelfBooks(wire)
    local books = {}
    for _idx, row in ipairs(wire.data.detail_list) do
        books[#books + 1] = {
            source_id = "fanqie",
            stable_id = tostring(row.book_id),
            title = row.book_name,
            authors = row.author_name,
            intro = require("utils.text").stripHtml(row.abstract),
            cover = row.thumb_url,
        }
    end
    return books
end

--- 书架远端：Shelf.syncAsync 要的三个冒号方法。
---@param self FanqieSource
---@param force boolean|nil
local function shelfRemote(self, force)
    local remote = {}
    function remote.shelfSyncAsync(_remote, cb)
        return self.client:fetchShelfDetailAsync(force, function(wire, err)
            if not wire then
                cb(nil, errMsg(err))
            elseif type(wire.data) ~= "table" or type(wire.data.detail_list) ~= "table" then
                cb(nil, _("番茄书架响应不完整，保留本地书架"))
            else
                require("utils.paths").ensureLayout("fanqie")
                cb(wire)
            end
        end)
    end
    function remote.addToShelfAsync(_remote, stable_id, cb)
        return self.client:shelfActionAsync("add", stable_id, cb)
    end
    function remote.removeFromShelfAsync(_remote, stable_id, cb)
        return self.client:shelfActionAsync("delete", stable_id, cb)
    end
    return remote
end

---@param opts { force?: boolean, dirty_only?: boolean, on_progress?: fun(text: string|nil, done: integer|nil, total: integer|nil) }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return CancelHandle|nil
---@param self FanqieSource
function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    if not self:configured() then
        if opts.dirty_only then return Base.skipped(cb, "fanqie not logged in") end
        return Base.defer(cb, nil, _("请在数据源设置中扫码登录番茄小说"))
    end
    return require("source.shelf").syncAsync(self.id, shelfRemote(self, opts.force), shelfBooks, opts, cb)
end

--- 未登录时书库就是唯一真相：标删后直接撕墓碑；登录后走基类三段式，由书架同步推删。
---@param identity BookIdentity
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function Source:deleteBookAsync(identity, cb)
    if self:configured() then return Base.deleteBookAsync(self, identity, cb) end
    if not require("book.store").markDeleted(self.id, identity.stable_id) then
        return Base.defer(cb, false, _("删除本书失败"))
    end
    if not require("book.books_db").remove(self.id, identity.stable_id) then
        require("utils.log").warn("book fanqie tombstone remove failed", identity.stable_id)
    end
    return Base.defer(cb, true)
end

--- 书城搜索：免登录端点，字段比书架少（没有字数 / 最新章）。
---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Source:searchAsync(keyword, cb)
    return self.client:searchAsync(keyword, function(wire, err)
        if not wire then
            cb(nil, errMsg(err))
            return
        end
        local FanQie = require("source.fanqie.fanqie")
        local books = {}
        local list = type(wire.data) == "table" and wire.data.ret_data
        for _idx, row in ipairs(type(list) == "table" and list or {}) do
            if row.book_id then
                books[#books + 1] = {
                    source_id = self.id,
                    stable_id = tostring(row.book_id),
                    title = row.title,
                    authors = row.author or "",
                    category = row.category,
                    intro = row.abstract,
                    cover = FanQie.mobileCover(row.thumb_url) or FanQie.mobileCover(row.audio_thumb_uri),
                }
            end
        end
        cb({ data = books })
    end)
end

--- 书城浏览：网页榜单，榜单（阅读榜 / 新书榜）× 频道（男 / 女）× 分类；节点是「频道:榜单:分类」，缺省男频阅读榜首个分类。
--- 页面只带前 10 本（分页接口要签名），分类列表取自页面本身。
---@param opts { node?: string }
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Source:browseAsync(opts, cb)
    local gender, kind, category = (opts.node or "1:2:"):match("^(%d):(%d):(%d*)$")
    return self.client:rankAsync(gender .. "_" .. kind .. (category ~= "" and "_" .. category or ""), function(html, err)
        local rank = html and require("source.fanqie.rank").state(html)
        if not rank then
            cb(nil, err and errMsg(err) or _("加载失败"))
            return
        end
        local cats, first = {}, nil
        for _idx, cat in ipairs(rank.rankCategoryTypeList[gender == "1" and "male" or "female"] or {}) do
            first = first or cat.id
            cats[#cats + 1] = { id = gender .. ":" .. kind .. ":" .. cat.id, title = cat.name }
        end
        local node = gender .. ":" .. kind .. ":" .. (category ~= "" and category or first or "")
        cb({
            data = require("source.fanqie.rank").books(rank, self.id),
            groups = {
                Browse.group({ { id = gender .. ":2:", title = _("阅读榜") }, { id = gender .. ":1:", title = _("新书榜") } },
                    gender .. ":" .. kind .. ":"),
                Browse.group({ { id = "1:" .. kind .. ":", title = _("男频") }, { id = "0:" .. kind .. ":", title = _("女频") } },
                    gender .. ":" .. kind .. ":"),
                Browse.group(cats, node),
            },
        })
    end)
end

function Source:getDetailAsync(identity, cb)
    return Base.defer(cb, identity.book or require("book.books_db").get(self.id, identity.stable_id))
end

function Source:loadTocAsync(identity, cb)
    local Toc = require("source.toc")
    local Content = require("source.fanqie.content")
    local cached = Toc.read(self.id, identity.stable_id)
    if cached and #cached > 0 then
        return Base.defer(cb, cached)
    end
    local h = handle()
    h.job = self.client:fetchChapterDirectoryAsync(identity.stable_id, function(wire, err)
        if h.cancelled then return end
        if not wire then
            cb(nil, errMsg(err))
            return
        end
        local rows = Content.readable_chapters(Content.normalize_chapters(wire))
        local toc = {}
        for _idx, row in ipairs(rows) do
            local w = tonumber(row.wordCount or row.word_count or row.words or row.chapterWordCount)
            toc[#toc + 1] = {
                idx = #toc + 1, uid = tostring(row.itemId), title = row.title,
                words = w and w > 0 and w or nil,
            }
        end
        if #toc == 0 then
            cb(nil, _("番茄目录为空"))
            return
        end
        if not Toc.put(self.id, identity.stable_id, toc) then
            cb(nil, _("章节目录保存失败"))
            return
        end
        cb(toc)
    end)
    return h
end

local function comicPath(identity, chapter)
    return Paths.bookWorkDir(identity.stable_id, identity.source_id) .. "/" .. chapter.uid .. ".cbz"
end

---@param url string
---@param cb fun(data: string|nil, err: any)
---@return { cancel: fun() }|nil
local function downloadImage(url, cb)
    return require("http.request").get(url, {
        accept = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
        headers = { ["Referer"] = "https://fanqienovel.com/" },
        timeout = require("http.timeout").net(3),
        allow_redirects = true,
    }, function(raw, err)
        if raw and raw ~= "" then cb(raw) else cb(nil, err) end
    end)
end

local function fetch(self, identity, chapter, cb)
    local Content = require("source.fanqie.content")
    local h = handle()
    Paths.ensureBookWork(identity.stable_id, identity.source_id)
    -- 已打好的漫画章节不再联网（也免去正文接口风控）
    local archive = comicPath(identity, chapter)
    if Cbz.ready(archive) then
        Base.defer(cb, { file = archive })
        return h
    end
    h.job = self.client:officialGetContentAsync(identity.stable_id, chapter.uid, function(result, err)
        if h.cancelled then return end
        if not result then
            cb(nil, errMsg(err))
            return
        end
        local title = result.title ~= "" and result.title or chapter.title
        local urls, key = Comic.parse(result.content)
        if not urls then
            -- 正文里的远程插图落到书籍工作目录；下不下来的图保留原地址，不拖垮整章。
            h.job = Assets.localizeAsync(Content.decode_pua_content(result.content),
                Paths.bookWorkDir(identity.stable_id, identity.source_id) .. "/images", downloadImage,
                function(html)
                    if h.cancelled then return end
                    cb({ title = title, html = html })
                end)
            return
        end
        h.job = Comic.materializeAsync(urls, key, comicPath(identity, chapter), function(path, err_msg)
            if h.cancelled then return end
            if path then cb({ title = title, file = path }) else cb(nil, err_msg) end
        end)
    end)
    return h
end

-- 番茄正文接口有设备风控，预取与整本下载都按这个间隔逐章请求。
local FETCH_INTERVAL = 6

---@return ChapterFetchContent
local function contentFetcher(self)
    return function(ref, ch, done) return fetch(self, ref, ch, done) end
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = contentFetcher(self),
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = contentFetcher(self),
        interval_seconds = FETCH_INTERVAL,
    }, cb)
end

--- 缓存整本章节正文；已落盘章节由公共实现自动跳过。
---@param identity BookIdentity
---@param on_progress fun(done: integer, total: integer)|nil
---@param cb fun(ok: boolean, cached: integer, err: string|nil, total: integer, failed: integer)
---@return { cancel: fun() }
function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    return require("source.chapter").cacheAllAsync(self, identity, contentFetcher(self), on_progress, cb,
        FETCH_INTERVAL, range)
end

function Source:getProgressAsync(identity, cb)
    local Toc = require("source.toc")
    local h = handle()
    h.job = self.client:fetchReadProgressAsync(function(wire, err)
        if h.cancelled then return end
        if not wire then
            cb(nil, errMsg(err))
            return
        end
        local row
        for _idx, item in ipairs(wire.data or {}) do
            if tostring(item.book_id) == identity.stable_id then
                row = item
                break
            end
        end
        if not row or not row.item_id then
            cb(nil, nil, { empty = true })
            return
        end
        h.job = self:loadTocAsync(identity, function(toc, reason)
            if h.cancelled then return end
            if not toc then
                cb(nil, reason)
                return
            end
            local idx = Toc.index(self.id, identity.stable_id, row.item_id)
            if not idx then
                cb(nil, nil, { empty = true })
                return
            end
            -- 服务端 read_progress 是整数（万分比）：我们推的 0..1 小数被截断成 0/1，
            -- 回读永远是 0，当章首会每次开书都采纳云端、跳回章首。≤1 视为没有章内位置，留 nil。
            local within = tonumber(row.read_progress)
            if within and within > 1 then
                within = math.min(1, within / 10000)
            else
                within = nil
            end
            cb({
                chapter_idx = idx,
                chapter_fraction = within,
                fraction = (idx - 1 + (within or 0)) / #toc,
                extra = { chapter_uid = tostring(row.item_id), chapter_idx = idx },
            })
        end)
    end)
    return h
end

function Source:putProgressAsync(identity, pos, cb)
    local h = handle()
    h.job = self:loadTocAsync(identity, function(toc, err)
        if h.cancelled then return end
        if not toc then
            cb(nil, err)
            return
        end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter then
            cb(nil, _("缺少番茄章节位置"))
            return
        end
        h.job = self.client:updateReadProgressAsync(
            identity.stable_id, chapter.uid, idx - 1,
            math.max(0, math.min(1, tonumber(pos.chapter_fraction) or 0)),
            function(wire, reason)
                if h.cancelled then return end
                if not wire or tonumber(wire.code or 0) ~= 0 then
                    cb(nil, reason and errMsg(reason) or _("番茄进度上传失败"))
                    return
                end
                cb(true)
            end)
    end)
    return h
end

--- 阅读页是否显示他人段评（设置页开关，默认关）。
---@return boolean
function Source:paragraphReviewsEnabled()
    return self.settings:get("show_paragraph_reviews", false) == true
end

--- 章节序号 → 番茄 item_id，目录来自缓存或在线拉取。
local function withChapterUid(self, identity, cb, start)
    local h = handle()
    h.job = self:loadTocAsync(identity, function(toc, err)
        if h.cancelled then return end
        local chapter = toc and toc[tonumber(identity.chapter_idx)]
        if not chapter then
            cb(nil, err or _("缺少番茄章节位置"))
            return
        end
        h.job = start(chapter.uid, cb)
    end)
    return h
end

--- 本章有评论的段落（未定位）。
---@param identity BookIdentity
---@param cb fun(hotspots: FanqieReviewHotspot[]|nil, err: string|nil)
---@return CancelHandle
function Source:paragraphHotspotsAsync(identity, cb)
    return ReviewCache.hotspotsAsync(identity, function(done)
        return withChapterUid(self, identity, done, function(uid, finish)
            return require("source.fanqie.reviews").hotspotsAsync(self.settings, uid, finish)
        end)
    end, cb)
end

--- 段落按段末文字定位到章节 HTML（子进程里跑，不碰实例状态）。
---@param hotspots FanqieReviewHotspot[]
---@param html string
---@return table[]
function Source:locateHotspots(hotspots, html)
    return require("source.fanqie.reviews").locate(hotspots, html)
end

--- 某段的一页评论；range 是段落序号，max_idx 是游标偏移（首页 0）。
---@param identity BookIdentity
---@param range string
---@param max_idx integer
---@param cb fun(page: WechatReviewPage|nil, err: string|nil)
---@return CancelHandle
function Source:paragraphReviewPageAsync(identity, range, max_idx, cb)
    return ReviewCache.pageAsync(identity, range, max_idx, function(done)
        return withChapterUid(self, identity, done, function(uid, finish)
            return require("source.fanqie.reviews").pageAsync(
                self.settings, identity.stable_id, uid, tonumber(range), max_idx, finish)
        end)
    end, cb)
end

return M
