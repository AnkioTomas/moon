--[[--
18ta 书源：分类浏览 + 按章在线阅读。

站点搜索维护中，足迹只存浏览器本地；接分类与完本、详情、目录、分页正文与整本缓存。

@module koplugin.book.source.18ta
--]]

local Browse = require("source.browse")
local Client = require("source.18ta.client")
local Mapper = require("source.18ta.mapper")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("l10n").get("source.18ta")

local T18ta = {}

-- 接口按 IP 限流，逐章请求之间留间隔。
local FETCH_INTERVAL = 1

---@return BookSourceMeta
function T18ta.meta()
    return SourceBase.loadMeta("18ta")
end

---@class T18taSource : SourceBase
---@field client T18taClient
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return T18taSource
function T18ta.new()
    local meta = T18ta.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type, client = Client.new() }, Source)
end

function Source:configured()
    return true
end

function Source:capabilities()
    return { scrape = false, edit = false, stats_pull = false, shelf_cache = false, shelf_push = false }
end

function Source:browseAsync(opts, cb)
    opts = opts or {}
    local node = opts.node
    -- 兼容旧版保存的数字分类；新节点直接使用官网路径。
    if node and node:match("^%d+$") then node = "/sort/" .. node .. "/1.html" end
    node = Mapper.storeNode(node) or "/sort/"
    local groups
    return Browse.pages(function(page, page_cb)
        return self.client:listAsync(node, page, function(body, err)
            if not body then page_cb(nil, err) return end
            local books = Mapper.list(body)
            local filters = Mapper.storeGroups(body, node)
            if not books or not filters then page_cb(nil, _("响应无效")); return end
            groups = filters
            page_cb(books, nil, Mapper.storeMore(body, node, page))
        end)
    end, opts.limit or 60, {}, function(result, err)
        if result then result.groups = groups end
        cb(result, err)
    end)
end

function Source:getDetailAsync(identity, cb)
    return self.client:bookAsync(identity.stable_id, function(html, err)
        if not html then cb(nil, err) return end
        local row = Mapper.book(html)
        if not row then
            cb(nil, _("无法解析书籍信息"))
            return
        end
        local book = {
            source_id = self.id,
            stable_id = identity.stable_id,
            title = row.title,
            authors = row.authors,
            category = row.category,
            intro = row.intro,
            cover = row.cover,
            meta = row.meta,
        }
        cb(require("book.store").rememberDetail(book))
    end)
end

function Source:loadTocAsync(identity, cb, force)
    if force then return self:refreshTocAsync(identity, cb) end
    local cancelled, active = false, nil
    active = Toc.readAsync(self.id, identity.stable_id, function(cached, err)
        if cancelled then return end
        if cached and #cached > 0 then cb(cached); return end
        if err then cb(nil, err); return end
        active = self:refreshTocAsync(identity, cb)
    end)
    return { cancel = function()
        cancelled = true
        if active then active.cancel() end
    end }
end

function Source:refreshTocAsync(identity, cb)
    local cancelled, active, pending = false, nil, true
    local request = self.client:bookAsync(identity.stable_id, function(html, err)
        pending = false
        if cancelled then return end
        if not html then cb(nil, err) return end
        active = Toc.parseAsync(self.id, identity.stable_id, function()
            local toc = Mapper.toc(html)
            if #toc == 0 then return nil, _("章节列表为空") end
            return toc
        end, cb)
    end)
    if pending then active = request end
    return { cancel = function()
        cancelled = true
        if active then active.cancel() end
    end }
end

---@return ChapterFetchContent
local function contentFetcher(self)
    return function(_ref, ch, done)
        return self.client:contentAsync(ch.origin, function(html, err)
            if not html then done(nil, err) return end
            done({ title = ch.title, html = html, mark = Mapper.CONTENT_MARK })
        end)
    end
end

--- 离线保留旧缓存；在线重取未标记的旧版单页正文，失败不覆盖它。
---@param path string
---@return boolean
local function reuse(path)
    if not require("ui/network/manager"):isConnected() then return true end
    local file = assert(io.open(path, "rb"))
    local head, err = file:read(64)
    file:close()
    assert(head, err)
    return head:find(Mapper.CONTENT_MARK, 1, true) ~= nil
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = contentFetcher(self),
        reuse = reuse,
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = contentFetcher(self),
        interval_seconds = FETCH_INTERVAL,
        reuse = reuse,
    }, cb)
end

--- 缓存整本章节正文；已落盘章节由公共实现自动跳过。
---@param identity BookIdentity
---@param on_progress fun(done: integer, total: integer)|nil
---@param cb fun(ok: boolean, cached: integer, err: string|nil, total: integer, failed: integer)
---@return { cancel: fun() }
function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    return require("source.chapter").cacheAllAsync(self, identity, contentFetcher(self), on_progress, cb,
        FETCH_INTERVAL, range, reuse)
end

return T18ta
