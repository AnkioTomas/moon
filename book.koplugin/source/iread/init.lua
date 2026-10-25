--[[--
iRead（iread.ankio.net）数据源。

个人 Token 鉴权（setting.lua）。书架是服务端的收藏记录，书城搜索的书加入书库时经 /book/favourite 收藏，本地删除会上行；
目录 / 正文按章落盘走公共 source/chapter；进度只到章，开书拉取、关书上报。笔记和统计没有接口。
服务端的书记录（bookUrl / sourceId 等）是目录、正文接口的必要参数，源实例按书名缓存最近一次书架行，缺了再拉。

@module koplugin.book.source.iread
--]]

local Browse = require("source.browse")
local Client = require("source.iread.client")
local Mapper = require("source.iread.mapper")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("gettext")

local IRead = {}

---@return BookSourceMeta
function IRead.meta()
    return require("source.meta").get("iread")
end

---@class IReadSource : SourceBase
---@field rows table<string, table>|nil 书名 → 最近一次书架行
---@field found table<string, table>|nil 书名 → 最近一次搜索行（收藏时整行带回）
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return IReadSource
function IRead.new()
    local meta = IRead.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

---@return boolean
function Source:configured()
    return Client.credential() ~= nil
end

---@param rows table[]
---@param stable_id string
---@return table|nil
local function findRow(rows, stable_id)
    for _idx, row in ipairs(rows) do
        if row.name == stable_id then return row end
    end
    return nil
end

--- 拉书架并刷新行缓存。
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Source:fetchShelf(cb)
    return Client.shelfAsync(function(rows, err)
        if not rows then cb(nil, err); return end
        local cache = {}
        for _idx, row in ipairs(rows) do cache[row.name] = row end
        self.rows = cache
        cb(rows)
    end)
end

--- 书架远端：Shelf.syncAsync 要的三个冒号方法。收藏接口是开关，加入前先确认远端还没有这本书。
local Remote = {}

function Remote:shelfSyncAsync(cb) return self.source:fetchShelf(cb) end

--- 要收藏的行来自搜索缓存（`found`）；没有缓存（只在本地加过、没搜过）无法收藏。
function Remote:addToShelfAsync(stable_id, cb)
    local row = self.source.found and self.source.found[stable_id]
    if not row then return SourceBase.defer(cb, nil, _("请先搜索这本书再加入书库")) end
    local cancelled, job = false, nil
    job = Client.shelfAsync(function(rows, err)
        if cancelled then return end
        if not rows then cb(nil, err); return end
        if findRow(rows, stable_id) then cb(true); return end
        job = Client.removeAsync(row, cb)
    end)
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

--- 远端已经没有这本书就算删除完成（收藏接口是开关，不能盲调）。
function Remote:removeFromShelfAsync(stable_id, cb)
    local cancelled, job = false, nil
    job = self.source:fetchShelf(function(rows, err)
        if cancelled then return end
        if not rows then cb(nil, err); return end
        local row = findRow(rows, stable_id)
        if not row then cb(true); return end
        job = Client.removeAsync(row, cb)
    end)
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "iread not logged in") end
    local remote = setmetatable({ source = self }, { __index = Remote })
    return Shelf.syncAsync(self.id, remote, Mapper.shelfList, opts, cb)
end

function Source:syncNotesAsync(_opts, cb)
    return SourceBase.skipped(cb, "iread has no notes")
end

function Source:syncStatsAsync(_opts, cb)
    return SourceBase.skipped(cb, "iread has no stats")
end

--- 书城搜索：回包形状同 listStoreAsync。搜索行同书架行，缓存起来供目录 / 正文接口使用。
---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Source:searchAsync(keyword, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录 iRead")) end
    return Client.searchAsync(keyword, function(rows, err)
        if not rows then cb(nil, err); return end
        self.found = self.found or {}
        local uniq, seen = {}, {}
        for _idx, row in ipairs(rows) do
            if not seen[row.name] then
                seen[row.name] = true
                self.found[row.name] = row
                uniq[#uniq + 1] = row
            end
        end
        cb({ data = Mapper.shelfList(uniq) })
    end)
end

--- 书城浏览：服务端每次随机给一个书源的「发现」入口（榜单 / 分类），入口就是 chip，节点是「书源 id:入口序号」；
--- 书源规则缓存在实例上，「换一批」重取规则。结果行与搜索同形，进 self.found 供加书架。
---@param opts { node?: string }
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Source:browseAsync(opts, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录 iRead")) end
    local handle = {}
    function handle.cancel()
        if handle.inner then handle.inner.cancel() end
    end
    local function explore(rule, node)
        local chips, picked = {}, nil
        for idx, entry in ipairs(rule.exploreUrl) do
            if entry.url and entry.url ~= "" then
                local id = rule.id .. ":" .. idx
                chips[#chips + 1] = { id = id, title = entry.title }
                if id == node then picked = entry end
            end
        end
        local groups = { Browse.group(chips, node), { chips = { { id = "next", title = _("换一批书源") } } } }
        if not picked then
            cb({ data = {}, groups = groups })
            return
        end
        handle.inner = Client.exploreAsync(rule.id, picked.url, function(rows, err)
            if not rows then cb(nil, err); return end
            self.found = self.found or {}
            for _idx, row in ipairs(rows) do self.found[row.name] = row end
            cb({ data = Mapper.shelfList(rows), groups = groups })
        end)
    end
    local sid = tonumber((opts.node or ""):match("^(%d+):"))
    local cached = sid and self.explore_rules and self.explore_rules[sid]
    if cached then
        explore(cached, opts.node)
        return handle
    end
    handle.inner = Client.exploreRulesAsync(function(rules, err)
        if not rules then cb(nil, err); return end
        local rule
        for _idx, candidate in ipairs(rules) do
            if type(candidate.exploreUrl) == "table" and #candidate.exploreUrl > 0 then rule = candidate end
        end
        if not rule then cb(nil, _("iRead 暂无发现入口")); return end
        self.explore_rules = self.explore_rules or {}
        self.explore_rules[rule.id] = rule
        explore(rule, nil)
    end)
    return handle
end

--- 取书架行再交给 fn(row)（返回它发起的任务，取消时一并取消）；fresh 为真强制重拉书架
--- （上报进度要覆盖整行，不能用旧行）。
---@param identity BookIdentity
---@param fresh boolean
---@param cb function
---@param fn fun(row: table): { cancel: fun() }|nil
---@return { cancel: fun() }
function Source:withRow(identity, fresh, cb, fn)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录 iRead")) end
    local cached = not fresh and self.rows and self.rows[identity.stable_id]
    if cached then return fn(cached) or SourceBase.defer(function() end) end
    local cancelled, job = false, nil
    job = self:fetchShelf(function(rows, err)
        if cancelled then return end
        if not rows then cb(nil, err); return end
        local row = findRow(rows, identity.stable_id)
        if not row then cb(nil, _("这本书不在 iRead 书架上")); return end
        job = fn(row) or job
    end)
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

function Source:getProgressAsync(identity, cb)
    return self:withRow(identity, true, cb, function(row)
        local read = Mapper.readPos(row)
        if not read then cb(nil, nil, { empty = true }); return nil end
        return self:loadTocAsync(identity, function(toc, reason)
            if not toc then cb(nil, reason); return end
            local idx = math.min(read.index + 1, #toc)
            cb({
                chapter_idx = idx,
                chapter_title = read.title or toc[idx].title,
                fraction = (idx - 1) / #toc,
                extra = { chapter_uid = toc[idx].uid, chapter_idx = idx },
            })
        end)
    end)
end

function Source:putProgressAsync(identity, pos, cb)
    return self:withRow(identity, true, cb, function(row)
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        if not idx then cb(nil, _("缺少阅读章节位置")); return nil end
        local toc = Toc.read(self.id, identity.stable_id)
        local chapter = toc and toc[idx]
        local read = Mapper.readPos(row)
        return Client.saveProgressAsync(row, {
            index = idx - 1,
            title = chapter and chapter.title,
            offset = read and read.index == idx - 1 and read.offset or 0,
        }, cb)
    end)
end

--- 书库里已有的元数据。
function Source:getDetailAsync(identity, cb)
    return SourceBase.defer(cb, identity.book or require("book.books_db").get(self.id, identity.stable_id))
end

function Source:loadTocAsync(identity, cb)
    local cached = Toc.read(self.id, identity.stable_id)
    if cached and #cached > 0 then
        return SourceBase.defer(cb, cached)
    end
    return self:withRow(identity, false, cb, function(row)
        return Client.chaptersAsync(row, function(rows, err)
            if not rows then cb(nil, err); return end
            local toc = Mapper.toc(rows)
            if not Toc.put(self.id, identity.stable_id, toc) then cb(nil, _("章节目录保存失败")); return end
            cb(toc)
        end)
    end)
end

---@return ChapterFetchContent
function Source:contentFetcher()
    return function(identity, chapter, done)
        return self:withRow(identity, false, done, function(row)
            return Client.contentAsync(row, chapter.raw, tonumber(chapter.uid), function(text, err)
                if not text then done(nil, err); return end
                done({ title = chapter.title, html = require("utils.text").chapterHtml(chapter.title, Mapper.text(text)) })
            end)
        end)
    end
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = self:contentFetcher(),
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = self:contentFetcher(),
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    return require("source.chapter").cacheAllAsync(self, identity, self:contentFetcher(), on_progress, cb, 0, range)
end

return IRead
