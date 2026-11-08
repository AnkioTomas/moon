--[[--
知音漫客数据源。

阅读发生在站点跳过去的看漫画。账号登录与公开阅读分离；登录后拉取收藏。
一话是一组图片，打成 CBZ。

@module source.zymk
--]]

local Client = require("source.zymk.client")
local Mapper = require("source.zymk.mapper")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("l10n").get("source.zymk")

local Zhiyinmanke = {}

---@return BookSourceMeta
function Zhiyinmanke.meta()
    return SourceBase.loadMeta("zymk")
end

---@class ZhiyinmankeSource : SourceBase
---@field account ZymkAccount|nil
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return ZhiyinmankeSource
function Zhiyinmanke.new()
    local meta = Zhiyinmanke.meta()
    return setmetatable({
        id = meta.id, name = meta.name, type = meta.type,
        account = require("utils.settings").getSource("zymk").account,
    }, Source)
end

--- 只拉收藏，不推本地成员变更。
---@return SourceCapabilities
function Source:capabilities()
    local caps = SourceBase.capabilities(self)
    caps.shelf_push = false
    return caps
end

---@return boolean
function Source:configured()
    return true
end

---@param opts { force?: boolean, dirty_only?: boolean, on_progress?: ShelfReport }|nil
---@param cb fun(result: SyncResult|nil, err: string|nil)
function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    if opts.dirty_only then return SourceBase.skipped(cb, "unsupported") end
    if not self.account then return SourceBase.skipped(cb, "zymk not logged in") end
    if opts.on_progress then opts.on_progress(_("正在拉取书架…")) end
    local cancelled = false
    local job = Client.shelfAsync(self.account, function(books, err)
        if cancelled then return end
        if not books then cb(nil, err); return end
        local result, reason = require("source.shelf").reconcile(self.id, books, opts.force, true)
        cb(result, reason)
    end)
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
function Source:searchAsync(keyword, cb)
    return Client.searchAsync(keyword, function(books, err)
        if not books then cb(nil, err or _("请求失败")); return end
        cb({ data = books })
    end)
end

---@param opts table|nil
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
function Source:browseAsync(opts, cb)
    return require("source.zymk.browse").run(opts or {}, cb)
end

function Source:bookReviewsAsync(identity, cb)
    return Client.reviewsAsync(identity.stable_id, 1, cb)
end

---@param self ZhiyinmankeSource
---@param identity BookIdentity
---@param cb fun(page: table|nil, err: string|nil)
local function loadPage(self, identity, cb)
    return Client.catalogAsync(identity.stable_id, function(page, err)
        if not page then cb(nil, err); return end
        if not Toc.put(self.id, identity.stable_id, page.chapters) then cb(nil, _("章节目录保存失败")); return end
        cb(page)
    end)
end

function Source:getDetailAsync(identity, cb)
    return loadPage(self, identity, function(page, err)
        if page and page.book then cb(require("book.store").rememberDetail(page.book)); return end
        local row = identity.book or require("book.books_db").get(self.id, identity.stable_id)
        if row then cb(row); return end
        cb(nil, err or _("请求失败"))
    end)
end

function Source:loadTocAsync(identity, cb, force)
    if not force then
        local cached = Toc.read(self.id, identity.stable_id)
        if cached and #cached > 0 and cached[1].toc_version == Mapper.TOC_VERSION then
            return SourceBase.defer(cb, cached)
        end
    end
    return loadPage(self, identity, function(page, err)
        if not page then cb(nil, err); return end
        cb(page.chapters)
    end)
end

Source.refreshTocAsync = function(self, identity, cb)
    return self:loadTocAsync(identity, cb, true)
end

---@param identity BookIdentity
---@param opts table
---@param toc BookChapter[]
---@return integer
local function startIndex(identity, opts, toc)
    local idx = opts.chapter_idx
    if not idx then
        local pending = require("book.progress_db").get(identity.source_id, identity.stable_id)
        idx = pending and (pending.chapter_idx or math.floor((pending.fraction or 0) * #toc) + 1)
    end
    return math.max(1, math.min(#toc, idx or 1))
end

---@param identity BookIdentity
---@param opts table|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:openBookAsync(identity, opts, cb)
    opts = opts or {}
    local Chapter = require("source.zymk.chapter")
    local function finish(path, idx)
        local ok, err = require("book.store").touch(path, identity, {
            chapter_idx = idx,
            book = identity.book,
        })
        cb(ok and path or nil, err)
    end
    local toc = Toc.read(identity.source_id, identity.stable_id)
    if toc and #toc > 0 then
        local idx = startIndex(identity, opts, toc)
        local path = Chapter.existing(identity, toc[idx])
        if path then return SourceBase.defer(finish, path, idx) end
    end
    if not require("ui/network/manager"):isConnected() then
        return SourceBase.defer(cb, nil, _("网络不可用，请先连接 Wi-Fi"))
    end

    local cancelled, active, dialog = false, nil, nil
    local function closeDialog()
        if dialog then dialog:close(); dialog = nil end
    end
    require("ui/uimanager"):nextTick(function()
        if cancelled then return end
        dialog = require("ui.themes.widgets.progress_dialog"):new{
            title = identity.book and identity.book.title or identity.stable_id,
            dismissable = false,
        }
        dialog:show()
        dialog:set(_("正在准备漫画…"))
        local loading = true
        local toc_job = self:loadTocAsync(identity, function(fresh, err)
            loading = false
            active = nil
            if cancelled then return end
            if not fresh then closeDialog(); cb(nil, err); return end
            local idx = startIndex(identity, opts, fresh)
            local preparing = true
            local chapter_job = Chapter.materializeAsync(identity, fresh[idx], function(done, total)
                if dialog and total > 0 then dialog:update(_("正在准备漫画…"), done, total) end
            end, function(path, materialize_err)
                preparing = false
                active = nil
                closeDialog()
                if cancelled then return end
                if not path then cb(nil, materialize_err); return end
                finish(path, idx)
            end)
            if preparing then active = chapter_job end
        end)
        if loading then active = toc_job end
    end)
    return { cancel = function()
        cancelled = true
        if active then active.cancel() end
        closeDialog()
    end }
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.zymk.chapter").prefetchAsync(identity, toc, from_idx, count, nil, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    local cancelled, active = false, nil
    local loading = true
    local toc_job = self:loadTocAsync(identity, function(toc, err)
        loading = false
        active = nil
        if cancelled then return end
        if not toc then cb(false, 0, err, 0, 0); return end
        local from_idx, count = require("source.chapter").cacheRange(toc, range)
        local caching = true
        local cache_job = require("source.zymk.chapter").prefetchAsync(identity, toc, from_idx, count, {
            progress = on_progress,
            interval_seconds = 1.5,
        }, function(cached, total, failed, last_err)
            caching = false
            active = nil
            if not cancelled then cb(failed == 0, cached, last_err, total, failed) end
        end)
        if caching then active = cache_job end
    end)
    if loading then active = toc_job end
    return { cancel = function()
        cancelled = true
        if active then active.cancel() end
    end }
end

return Zhiyinmanke
