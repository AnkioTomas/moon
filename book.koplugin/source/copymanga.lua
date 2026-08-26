--[[--
拷贝漫画数据源门面（在线按话阅读）。

协议移植自 kComics（lxdklp/kComics）。

@module koplugin.book.source.copymanga
--]]

local Client = require("source.copymanga.client")
local Mapper = require("source.copymanga.mapper")
local CChapter = require("source.copymanga.chapter")
local SourceBase = require("source.base")
local _ = require("gettext")

local Copymanga = {}

local TOC_TTL = 6 * 60 * 60

---@return BookSourceMeta
function Copymanga.meta()
    return { id = "copymanga", name = _("拷贝漫画"), type = "online" }
end

---@class CopymangaSource : SourceBase
---@field _client CopymangaClient
---@field _covers table<string, string>
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

function Copymanga.new()
    local meta = Copymanga.meta()
    ---@type CopymangaSource
    local self = setmetatable({
        id = meta.id,
        name = meta.name,
        type = meta.type,
        _client = Client:new(),
        _covers = {},
    }, Source)
    return self
end

---@param self CopymangaSource
---@param stable_id string
---@param url string
local function rememberCover(self, stable_id, url)
    if type(stable_id) == "string" and type(url) == "string" and url:find("^https?://", 1) then
        self._covers[stable_id] = url
    end
end

function Source:capabilities()
    return {
        search = true,
        refresh = false,
        scrape = false,
        insight = false,
        store = true,
    }
end

function Source:configured()
    return self._client:configured()
end

function Source:clearCaches()
    self._covers = {}
end

function Source:close()
    self._covers = {}
end

function Source:coverRequest(identity)
    local url = self._covers[identity.stable_id]
    if type(url) ~= "string" or url == "" then
        return nil, _("无封面")
    end
    return {
        url = url,
        headers = require("source.copymanga.auth").headers(),
    }
end

function Source:syncBooksAsync(_opts, cb)
    if not require("source.copymanga.auth").hasSession() then
        return require("source.base").syncBooksAsync(self, _opts, cb)
    end
    local cancelled, job = false, nil
    local offset, limit, books = 0, 36, {}
    local function nextPage()
        if cancelled then return end
        job = self._client:favoritesAsync(limit, offset, function(wire, err)
            if cancelled then return end
            if not wire then
                cb(nil, err)
                return
            end
            local mapped = Mapper.list(wire, function(id, url)
                rememberCover(self, id, url)
            end)
            for _, book in ipairs(mapped.data or {}) do
                books[#books + 1] = book
            end
            local total = tonumber((wire.results or wire).total) or #books
            offset = offset + limit
            if offset < total and #(mapped.data or {}) > 0 then
                nextPage()
                return
            end
            job = require("book.store").reconcileAsync(self.id, books, nil, cb)
        end)
    end
    nextPage()
    return {
        cancel = function()
            cancelled = true
            if job and job.cancel then job.cancel() end
        end,
    }
end

function Source:listStoreAsync(opts, cb)
    opts = opts or {}
    local page = tonumber(opts.page) or 1
    local page_size = tonumber(opts.page_size) or 20
    local offset = (page - 1) * page_size
    local search = tostring(opts.search or "")
    local function done(wire, err)
        if wire then
            cb(Mapper.list(wire, function(id, url)
                rememberCover(self, id, url)
            end))
        else
            cb(nil, err)
        end
    end
    if search == "" then
        return self._client:browseAsync(page_size, offset, done)
    end
    return self._client:searchAsync(search, page_size, offset, done)
end

function Source:getDetailAsync(identity, cb)
    return self._client:comicInfoAsync(identity.stable_id, function(wire, err)
        if not wire then
            cb(nil, err)
            return
        end
        local book, _groups, cover = Mapper.detail(wire)
        if not book then
            cb(nil, _("漫画详情为空"))
            return
        end
        if cover then rememberCover(self, book.stable_id, cover) end
        cb(book)
    end)
end

local function fetchAllChaptersAsync(client, path_word, groups, cb)
    local rows, group_idx, group_offset, cancelled, job = {}, 1, 0, false, nil

    local function fail(err)
        if not cancelled then cb(nil, err) end
    end

    local function fetchGroupPage()
        if cancelled then return end
        local group = groups[group_idx]
        if not group then
            cb(Mapper.chapters(rows))
            return
        end
        job = client:chaptersAsync(path_word, group.path_word, group_offset, function(wire, err)
            if cancelled then return end
            if not wire then
                fail(err)
                return
            end
            local page, total = Mapper.chapterPage(wire)
            for _, item in ipairs(page) do
                rows[#rows + 1] = item
            end
            group_offset = group_offset + 100
            if group_offset < total and #page > 0 then
                fetchGroupPage()
                return
            end
            group_idx = group_idx + 1
            group_offset = 0
            fetchGroupPage()
        end)
    end

    fetchGroupPage()
    return {
        cancel = function()
            cancelled = true
            if job and job.cancel then job.cancel() end
        end,
    }
end

local function loadGroupsAsync(client, path_word, cb)
    return client:comicInfoAsync(path_word, function(wire, err)
        if not wire then
            cb(nil, err)
            return
        end
        local _book, groups = Mapper.detail(wire)
        if not groups or #groups == 0 then
            cb({ { name = "默认", path_word = "default" } })
            return
        end
        cb(groups)
    end)
end

local function getTocAsync(self, identity, cb)
    local payload = require("utils.db.toc").get(identity.source_id, identity.stable_id, TOC_TTL)
    if payload then
        local ok, cached = pcall(function() return require("json").decode(payload) end)
        if ok and type(cached) == "table" and #cached > 0 then
            require("ui/uimanager"):nextTick(function() cb(cached) end)
            return
        end
    end
    local cancelled, job1, job2 = false, nil, nil
    job1 = loadGroupsAsync(self._client, identity.stable_id, function(groups, err)
        if cancelled then return end
        if not groups then
            cb(nil, err)
            return
        end
        job2 = fetchAllChaptersAsync(self._client, identity.stable_id, groups, function(chapters, cerr)
            if cancelled then return end
            if not chapters then
                cb(nil, cerr)
                return
            end
            local ok, encoded = pcall(function() return require("json").encode(chapters) end)
            if ok and encoded then
                require("utils.db.queue").run(function()
                    require("utils.db.toc").upsert(identity.source_id, identity.stable_id, encoded)
                end)
            end
            cb(chapters)
        end)
    end)
    return {
        cancel = function()
            cancelled = true
            if job1 and job1.cancel then job1.cancel() end
            if job2 and job2.cancel then job2.cancel() end
        end,
    }
end

function Source:openBookAsync(identity, opts, cb)
    return require("source.chapter").openWithUi(self, identity, identity.book, opts, {
        loadToc = function(r, done) return getTocAsync(self, r, done) end,
        fetchContent = function(_r, chapter, done)
            return CChapter.fetchContentAsync(identity.stable_id, chapter, done)
        end,
    }, cb)
end

--- 阅读中后台预取后续章节。
---@param identity BookIdentity
---@param toc BookChapter[]
---@param from_idx integer
---@param count integer
---@param cb fun()|nil
---@return { cancel: fun() }
function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = function(_r, chapter, done)
            return CChapter.fetchContentAsync(identity.stable_id, chapter, done)
        end,
    }, cb)
end

return Copymanga
