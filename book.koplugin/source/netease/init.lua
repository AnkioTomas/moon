--[[--
网易云阅读数据源。

搜索、榜单和免费章节不需要登录。未购买章节给一页提示。
手机号密码或微信扫码登录后，电脑端 Cookie 用于书架与阅读。
书架本地优先增删，联网后经公共书架同步推到官网。

@module koplugin.book.source.netease
--]]

local Browse = require("source.browse")
local Client = require("source.netease.client")
local Mapper = require("source.netease.mapper")
local SourceBase = require("source.base")
local Text = require("utils.text")
local Toc = require("source.toc")
local _ = require("l10n").get("source.netease")

local Netease = {}

---@return BookSourceMeta
function Netease.meta()
    return SourceBase.loadMeta("netease")
end

---@class NeteaseSource : SourceBase
local Source = setmetatable({ shelf_add = true }, { __index = SourceBase })
Source.__index = Source

---@return NeteaseSource
function Netease.new()
    local meta = Netease.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

--- 未登录仍可搜索和读免费章节。进度上行只在登录后发生，避免每次唤醒都重试。
---@return boolean
function Source:configured()
    return Client.loggedIn()
end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "netease not logged in") end
    return require("source.shelf").syncAsync(self.id, Client, nil, opts, cb)
end

---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
function Source:searchAsync(keyword, cb)
    return Client.searchAsync(keyword, function(books, err)
        if not books then cb(nil, err or _("请求失败")); return end
        cb({ data = books })
    end)
end

---@param opts { node?: string, limit?: integer }|nil
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
function Source:browseAsync(opts, cb)
    local node = opts and opts.node or ""
    local channel, category, sort, pay, state = node:match(
        "^(%a+):(%w+):(%a+):([012]):([012])$")
    channel = channel or node
    if channel ~= "male" and channel ~= "female" and channel ~= "publish" then channel = "male" end
    if sort ~= "new" then sort = "hot" end
    category, pay, state = category or "all", pay or "0", state or "0"
    if channel == "publish" then state = "0" end
    local cancelled, job, pending = false, nil, true
    local initial = Client.categoriesAsync(function(categories, err)
        pending = false
        if cancelled then return end
        if not categories then cb(nil, err); return end
        local valid = category == "all"
        for _idx, row in ipairs(categories[channel]) do
            if row.id == category then valid = true end
        end
        if not valid then category = "all" end
        local values = { channel, category, sort, pay, state }
        local function chips(title, rows, position)
            local list = {}
            for _idx, row in ipairs(rows) do
                local node = { unpack(values) }
                node[position] = row.id
                if position == 1 then node[2], node[5] = "all", "0" end
                list[#list + 1] = { id = table.concat(node, ":"), title = row.title }
            end
            local active = { unpack(values) }
            if position == 1 then active[2], active[5] = "all", "0" end
            local group = Browse.group(list, table.concat(active, ":"))
            group.title = title
            return group
        end
        local cats = { { id = "all", title = _("全部") } }
        for _idx, row in ipairs(categories[channel]) do cats[#cats + 1] = row end
        local groups = {
            chips(nil, {
                { id = "male", title = _("男频") }, { id = "female", title = _("女频") },
                { id = "publish", title = _("出版") },
            }, 1),
            chips(_("分类"), cats, 2),
            chips(_("排序"), { { id = "hot", title = _("热门") }, { id = "new", title = _("最新") } }, 3),
            chips(_("价格"), {
                { id = "0", title = _("全部") }, { id = "1", title = _("免费") }, { id = "2", title = _("付费") },
            }, 4),
        }
        if channel ~= "publish" then
            groups[#groups + 1] = chips(_("状态"), {
                { id = "0", title = _("全部") }, { id = "1", title = _("连载中") }, { id = "2", title = _("已完结") },
            }, 5)
        end
        job = Browse.pages(function(page, done)
            return Client.catalogAsync({
                channel = channel, category = category, sort = sort, pay = pay, state = state,
            }, page, done)
        end, opts and opts.limit or 60, groups, function(result, reason)
            if not cancelled then cb(result, reason) end
        end)
    end)
    if pending then job = initial end
    return { cancel = function()
        cancelled = true
        if job then job:cancel() end
    end }
end

function Source:getDetailAsync(identity, cb)
    return Client.infoAsync(identity.stable_id, function(wire, err)
        local detail = wire and Mapper.detail(wire)
        if detail then cb(require("book.store").rememberDetail(detail)); return end
        local row = identity.book or require("book.books_db").get(self.id, identity.stable_id)
        if row then cb(row); return end
        cb(nil, err or _("请求失败"))
    end)
end

---@param self NeteaseSource
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
local function fetchTocAsync(self, identity, cb)
    return Client.infoAsync(identity.stable_id, function(wire, err)
        if not wire then cb(nil, err); return end
        local toc = Mapper.chapters(wire)
        if not toc or #toc == 0 then cb(nil, _("网易云阅读目录为空")); return end
        if not Toc.put(self.id, identity.stable_id, toc) then cb(nil, _("章节目录保存失败")); return end
        cb(toc)
    end)
end

function Source:loadTocAsync(identity, cb, force)
    if not force then
        local cached = Toc.read(self.id, identity.stable_id)
        if cached and #cached > 0 and (cached[1].toc_version == Mapper.TOC_VERSION
            or not require("ui/network/manager"):isConnected()) then
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
        local function finish(html, err)
            if html then
                if chapter.vip then Toc.markPaid("netease", identity.stable_id, chapter.uid, true) end
                done({ title = chapter.title, html = html })
                return
            end
            if not open or err ~= _("本章未购买") then done(nil, err); return end
            local notice = string.format(_("这是 VIP 章节，你还没有购买。\n请先在%s购买本章，再回来阅读。"), _("网易云阅读"))
            done({ title = chapter.title, html = Text.chapterHtml(chapter.title, notice), temporary = true })
        end
        if chapter.vip and not Client.loggedIn() then return finish(nil, _("本章未购买")) end
        return Client.contentAsync(identity.stable_id, chapter, finish)
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
    return Chapter.cacheAllAsync(self, identity, fetcher(false), on_progress, cb, nil, range, nil)
end

function Source:getProgressAsync(identity, cb)
    local cancelled, job = false, nil
    job = Client.infoAsync(identity.stable_id, function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        local toc = Mapper.chapters(wire)
        local idx = Mapper.progressIndex(wire)
        if not toc or not idx or not toc[idx] then cb(nil, nil, { empty = true }); return end
        if not Toc.put(self.id, identity.stable_id, toc) then cb(nil, _("章节目录保存失败")); return end
        local chapter_fraction = math.max(0, math.min(1, (tonumber(wire.curPagePercent) or 0) / 100))
        cb({
            chapter_idx = idx,
            chapter_title = toc[idx].title,
            chapter_fraction = chapter_fraction,
            fraction = (idx - 1 + chapter_fraction) / #toc,
            extra = { chapter_uid = toc[idx].uid, chapter_idx = idx, chapter_fraction = chapter_fraction },
        })
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

function Source:bookReviewsAsync(identity, cb)
    return Client.commentsAsync(identity.stable_id, function(items, err, pages)
        if not items then cb(nil, err); return end
        cb({ items = items, pages = pages })
    end)
end

function Source:putProgressAsync(identity, pos, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录网易云阅读")) end
    local cancelled, job, pending = false, nil, true
    local initial = self:loadTocAsync(identity, function(toc, err)
        pending = false
        if cancelled then return end
        if not toc then cb(nil, err); return end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        if idx then idx = math.floor(idx) end
        local chapter = idx and toc[idx]
        if not chapter then
            cb(nil, _("缺少网易云阅读章节位置"))
            return
        end
        job = Client.putProgressAsync(identity.stable_id, toc, idx, pos.chapter_fraction, function(ok, perr)
            cb(ok and true or nil, perr)
        end)
    end)
    if pending then job = initial end
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

return Netease
