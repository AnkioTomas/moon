--[[--
得到数据源。

扫码登录后同步已购电子书。目录和正文要阅读 token，正文是网页同款加密 SVG。

@module koplugin.book.source.dedao
--]]

local Client = require("source.dedao.client")
local Mapper = require("source.dedao.mapper")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local Text = require("utils.text")
local Browse = require("source.browse")
local JSON = require("json")
local _ = require("l10n").get("source.dedao")

local Dedao = {}

---@return BookSourceMeta
function Dedao.meta()
    return SourceBase.loadMeta("dedao")
end

---@class DedaoSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return DedaoSource
function Dedao.new()
    local meta = Dedao.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

---@return boolean
function Source:configured()
    return Client.loggedIn()
end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "dedao not logged in") end
    return Shelf.syncAsync(self.id, Client, Mapper.shelf, opts, cb)
end

---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
function Source:searchAsync(keyword, cb)
    return Browse.pages(function(page, done)
        return Client.searchAsync(keyword, function(body, err)
            if not body then done(nil, err); return end
            done(Mapper.search(body), nil, body.data.isMore == true or body.data.isMore == 1)
        end, page)
    end, 60, {}, cb)
end

local BROWSE_KEYS = {
    "classfc_name", "label_id", "navigation_id", "sort_strategy",
    "buy_strategy", "progress_strategy", "tags_ids",
}

local function browseQuery(values)
    ---@type table<string, string|integer|table>
    local query = { nav_type = 0, product_types = "2", page = 0, page_size = 20 }
    for _idx, key in ipairs(BROWSE_KEYS) do
        local value = values[key]
        if type(value) == "string" or key == "tags_ids" and type(value) == "table" and #value > 0 then
            query[key] = value
        end
    end
    return query
end

local function browseGroups(filters, request)
    local groups = {}
    local function add(options, key, active, title)
        local group = { title = title, chips = {} }
        for _idx, option in ipairs(options) do
            local value = browseQuery(request)
            value[key] = option.value
            if key == "navigation_id" then value.label_id = nil end
            if key == "tags_ids" then value.tags_ids = { option.value } end
            local id = JSON.encode(value)
            group.chips[#group.chips + 1] = { id = id, title = option.name }
            if option.value == active then group.active = id end
        end
        groups[#groups + 1] = group
    end
    local navigation = filters.navigations
    add(navigation.options, "navigation_id", request.navigation_id, navigation.title)
    for _idx, option in ipairs(navigation.options) do
        if option.value == request.navigation_id and type(option.sub_options) == "table" and #option.sub_options > 0 then
            add(option.sub_options, "label_id", request.label_id, navigation.title)
        end
    end
    for _idx, key in ipairs({ "sort_strategy", "buy_strategy", "progress_strategy", "tags" }) do
        local filter = filters[key]
        if type(filter) == "table" and not filter.is_hide and type(filter.options) == "table" then
            local field = key == "tags" and "tags_ids" or key
            local active = field == "tags_ids" and request.tags_ids and request.tags_ids[1] or request[field]
            add(filter.options, field, active or (filter.options[1] and filter.options[1].value), filter.title)
        end
    end
    return groups
end

function Source:browseAsync(opts, cb)
    opts = opts or {}
    local values = {}
    if opts.node then
        local decoded, node = pcall(JSON.decode, opts.node)
        if not decoded or type(node) ~= "table" then return SourceBase.defer(cb, nil, _("响应无效")) end
        values = node
    end
    local cancelled, pending, job = false, true, nil
    local initial = Client.browseFiltersAsync(browseQuery(values), function(body, err)
        pending = false
        if cancelled then return end
        if type(body) ~= "table" or type(body.request) ~= "table" or type(body.filter) ~= "table"
            or type(body.filter.navigations) ~= "table" or type(body.filter.navigations.options) ~= "table" then
            cb(nil, err or _("响应无效"))
            return
        end
        local query = browseQuery(body.request)
        local groups = browseGroups(body.filter, query)
        job = Browse.pages(function(page, done)
            return Client.browsePageAsync(query, page, function(data, reason)
                local list = Mapper.catalog(data)
                if not list then done(nil, reason or _("响应无效")); return end
                query.request_id = data.request_id
                done(list, nil, data.is_more == true or data.is_more == 1)
            end)
        end, opts.limit or 60, groups, cb)
    end)
    if pending then job = initial end
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

function Source:bookReviewsAsync(book, cb)
    return Client.reviewsAsync(book.stable_id, function(body, err)
        if not body then cb(nil, err); return end
        cb({ items = Mapper.reviews(body), total = body.total })
    end)
end

function Source:getDetailAsync(identity, cb)
    return Client.detailAsync(identity.stable_id, function(body, err)
        local detail = Mapper.detail(body, identity.stable_id)
        if detail then cb(require("book.store").rememberDetail(detail)); return end
        local row = identity.book or require("book.books_db").get(self.id, identity.stable_id)
        if row then cb(row); return end
        cb(nil, err or _("请求失败"))
    end)
end

---@param self DedaoSource
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
local function fetchTocAsync(self, identity, cb)
    return Client.bookInfoAsync(identity.stable_id, function(info, err)
        if not info then cb(nil, err); return end
        local toc = Mapper.chapters(info)
        if #toc == 0 then cb(nil, _("得到目录为空")); return end
        if not Toc.put(self.id, identity.stable_id, toc) then cb(nil, _("章节目录保存失败")); return end
        cb(toc)
    end)
end

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

local FLOW_MARK = "dedao-flow:1"

---@param open boolean
---@return ChapterFetchContent
local function fetcher(open)
    return function(identity, chapter, done)
        return Client.contentAsync(identity.stable_id, chapter.uid, function(text, err, kind)
            if text and not err then
                done({ title = chapter.title, html = text, mark = FLOW_MARK })
            elseif open and kind == "unpaid" then
                local notice = _("本书未购买，或试读额度已用完。\n请先在得到购买本书或开通电子书会员。")
                done({
                    title = chapter.title,
                    html = Text.chapterHtml(chapter.title, notice),
                    temporary = true,
                })
            else
                done(nil, err)
            end
        end)
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
    return Chapter.cacheAllAsync(self, identity, fetcher(false), on_progress, cb, nil, range)
end

function Source:getProgressAsync(identity, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录得到")) end
    local cancelled, pending, job = false, true, nil
    local initial = Client.progressAsync(identity.stable_id, function(item, err)
        pending = false
        if cancelled then return end
        if err then cb(nil, err); return end
        local uid = type(item) == "table" and Mapper.progressUid(item.findex) or nil
        if not uid then cb(nil, nil, { empty = true }); return end
        job = self:loadTocAsync(identity, function(toc, reason)
            if cancelled then return end
            if not toc or #toc == 0 then cb(nil, reason or _("得到目录为空")); return end
            local idx = Toc.index(self.id, identity.stable_id, uid)
            if not idx then cb(nil, nil, { empty = true }); return end
            local fraction = (idx - 1) / #toc
            cb({
                chapter_idx = idx,
                chapter_title = toc[idx].title,
                fraction = fraction,
                extra = { chapter_uid = uid, chapter_idx = idx },
            })
        end)
    end)
    if pending then job = initial end
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

function Source:putProgressAsync(identity, pos, cb)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未登录得到")) end
    local cancelled, pending, job = false, true, nil
    local initial = self:loadTocAsync(identity, function(toc, err)
        pending = false
        if cancelled then return end
        if not toc then cb(nil, err); return end
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter then cb(nil, _("缺少得到章节位置")); return end
        job = Client.putProgressAsync(identity.stable_id, chapter.uid, chapter.title, function(ok, perr)
            if cancelled then return end
            cb(ok and true or nil, perr)
        end)
    end)
    if pending then job = initial end
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

return Dedao
