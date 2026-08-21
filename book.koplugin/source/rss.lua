--[[--
RSS 数据源：feed = 书，item = 章。

@module koplugin.book.source.rss
--]]

local Client = require("source.rss.client")
local Mapper = require("source.rss.mapper")
local Parser = require("source.rss.parser")
local SourceBase = require("source.base")
local _ = require("gettext")

local RSS = {}

function RSS.meta()
    return { id = "rss", name = _("RSS 订阅"), type = "article" }
end

---@class RssSource : SourceBase
---@field cfg table
---@field _client table
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

function RSS.new()
    local meta = RSS.meta()
    return setmetatable({
        id = meta.id,
        name = meta.name,
        type = meta.type,
        cfg = require("utils.settings").getSource("rss"),
        _client = Client.new(),
    }, Source)
end

function Source:capabilities()
    return {
        search = true,
        refresh = true,
        scrape = false,
        insight = true,
        store = false,
    }
end

local function configuredFeeds(cfg)
    local out = {}
    local seen = {}
    for _, feed in ipairs(type(cfg.feeds) == "table" and cfg.feeds or {}) do
        local url = Parser.normalizeUrl(feed.url)
        if url and not seen[url] then
            seen[url] = true
            out[#out + 1] = {
                url = url,
                title = type(feed.title) == "string" and feed.title or nil,
            }
        end
    end
    return out
end

function Source:configured()
    return #configuredFeeds(self.cfg) > 0
end

function Source:clearCaches()
    self._client:clear()
end

function Source:close()
    self._client:clear()
end

local function findFeed(self, stable_id)
    local target = Parser.normalizeUrl(stable_id)
    for _, feed in ipairs(configuredFeeds(self.cfg)) do
        if feed.url == target then return feed end
    end
    return nil
end

--- RSS 目录会在头部插入新文章；章节文件却按 N.html 缓存。
--- 目录身份序列变化时清掉该 feed 的章节文件，避免 N 指向旧文章。
local function reconcileChapterCache(identity, chapters)
    local Paths = require("utils.paths")
    local lfs = require("libs/libkoreader-lfs")
    Paths.ensureBookWork(identity.stable_id, identity.source_id)
    local dir = Paths.bookWorkDir(identity.stable_id, identity.source_id)
    local fingerprint_path = dir .. "/rss-catalog"
    local ids = {}
    for _, chapter in ipairs(chapters) do
        ids[#ids + 1] = tostring(chapter.uid or chapter.source_idx or chapter.idx)
    end
    local fingerprint = table.concat(ids, "\n")
    local old
    local f = io.open(fingerprint_path, "rb")
    if f then old = f:read("*a"); f:close() end
    if old ~= nil and old ~= fingerprint then
        for name in lfs.dir(dir) do
            if name:match("^%d+%.html$") or name:match("^%d+%.html%.part$") then
                pcall(os.remove, dir .. "/" .. name)
            end
        end
    end
    if old ~= fingerprint then
        local tmp = fingerprint_path .. ".part"
        local out = io.open(tmp, "wb")
        if out then
            -- 写失败/rename 失败都清掉 .part 残留；指纹丢失无妨，下次按首次对账重写
            local wok = out:write(fingerprint) ~= nil
            out:close()
            if wok then
                os.remove(fingerprint_path)
                if not os.rename(tmp, fingerprint_path) then
                    os.remove(tmp)
                end
            else
                os.remove(tmp)
            end
        end
    end
end

---@param opts { force?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }
function Source:syncBooksAsync(opts, cb)
    if opts and opts.force then self._client:clear() end
    local feeds = configuredFeeds(self.cfg)
    local parsed = {}
    for _, feed in ipairs(feeds) do
        parsed[feed.url] = self._client:peek(feed.url)
    end
    local cancelled, job = false, nil
    require("ui/uimanager"):nextTick(function()
        if cancelled then return end
        local list = Mapper.library(feeds, parsed)
        job = require("book.store").reconcileAsync(self.id, list.data or {}, nil, cb)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job:cancel() end
    end }
end

function Source:getDetailAsync(identity, cb)
    local feed = findFeed(self, identity.stable_id)
    if not feed then
        cb(nil, _("订阅不存在"))
        return { cancel = function() end }
    end
    return self._client:fetchAsync(feed.url, nil, function(data, err)
        if data then cb(Mapper.detail(identity, feed, data)) else cb(nil, err) end
    end)
end

local function getTocAsync(self, identity, cb)
    local feed = findFeed(self, identity.stable_id)
    if not feed then
        cb(nil, _("订阅不存在"))
        return { cancel = function() end }
    end
    return self._client:fetchAsync(feed.url, nil, function(data, err)
        if not data then cb(nil, err); return end
        local chapters = Mapper.chapters(data)
        if #chapters == 0 then
            cb(nil, _("RSS 暂无文章"))
        else
            reconcileChapterCache(identity, chapters)
            cb(chapters)
        end
    end)
end

local function fetchChapterContentAsync(self, identity, chapter, cb)
    local feed = findFeed(self, identity.stable_id)
    if not feed then
        cb(nil, _("订阅不存在"))
        return { cancel = function() end }
    end
    return self._client:fetchAsync(feed.url, nil, function(data, err)
        if not data then cb(nil, err); return end
        cb(Mapper.chapterContent(data, chapter))
    end)
end

function Source:openBookAsync(identity, opts, cb)
    return require("source.chapter").openWithUi(self, identity, identity.book, opts, {
        loadToc = function(r, done) return getTocAsync(self, r, done) end,
        fetchContent = function(r, chapter, done)
            return fetchChapterContentAsync(self, r, chapter, done)
        end,
    }, cb)
end

return RSS
