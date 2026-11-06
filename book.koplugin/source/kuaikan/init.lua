--[[--
快看漫画数据源。

免费话不需要登录。收藏接口在未登录时返回空列表，对账会把书架清空，所以关掉书架上行。
一话是一组图片，打成 CBZ。

@module source.kuaikan
--]]

require("l10n").apply()
local Client = require("source.kuaikan.client")
local Mapper = require("source.kuaikan.mapper")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("gettext")

local Kuaikan = {}

---@return BookSourceMeta
function Kuaikan.meta()
    return SourceBase.loadMeta("kuaikan")
end

---@class KuaikanSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return KuaikanSource
function Kuaikan.new()
    local meta = Kuaikan.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

--- 未登录的收藏列表是空的，不能拿来对账。
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

---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
function Source:searchAsync(keyword, cb)
    return Client.searchAsync(keyword, function(books, err)
        if not books then cb(nil, err or _("请求失败")); return end
        cb({ data = books })
    end)
end

---@param _opts table|nil
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
function Source:browseAsync(_opts, cb)
    return Client.homeAsync(function(books, err)
        if not books then cb(nil, err or _("请求失败")); return end
        cb({ data = books })
    end)
end

---@param self KuaikanSource
---@param identity BookIdentity
---@param cb fun(page: table|nil, err: string|nil)
local function loadPage(self, identity, cb)
    return Client.topicAsync(identity.stable_id, function(page, err)
        if not page then cb(nil, err); return end
        local chapters = Mapper.chapters(page.chapters)
        if not chapters then cb(nil, _("漫画目录为空")); return end
        if not Toc.put(self.id, identity.stable_id, chapters) then cb(nil, _("章节目录保存失败")); return end
        page.chapters = chapters
        page.book = Mapper.detail(page.info, page.nickname)
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
    local Chapter = require("source.kuaikan.chapter")
    local function finish(path, idx)
        local ok, err = require("book.store").touch(path, identity, {
            chapter_idx = idx,
            book = identity.book,
        })
        cb(ok and path or nil, err)
    end
    local toc = Toc.read(identity.source_id, identity.stable_id)
    if toc then
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
        active = self:loadTocAsync(identity, function(fresh, err)
            active = nil
            if cancelled then return end
            if not fresh then closeDialog(); cb(nil, err); return end
            local idx = startIndex(identity, opts, fresh)
            active = Chapter.materializeAsync(identity, fresh[idx], function(done, total)
                if dialog and total > 0 then dialog:update(_("正在准备漫画…"), done, total) end
            end, function(path, materialize_err)
                active = nil
                closeDialog()
                if cancelled then return end
                if not path then cb(nil, materialize_err); return end
                finish(path, idx)
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active then active.cancel() end
        closeDialog()
    end }
end

function Source:bookReviewsAsync(identity, cb)
    return Client.commentsAsync(identity.stable_id, function(items, err, pages)
        if not items then cb(nil, err); return end
        cb({ items = items, pages = pages })
    end)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.kuaikan.chapter").prefetchAsync(identity, toc, from_idx, count, nil, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    local cancelled, active = false, nil
    active = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then cb(false, 0, err, 0, 0); return end
        local from_idx, count = require("source.chapter").cacheRange(toc, range)
        active = require("source.kuaikan.chapter").prefetchAsync(identity, toc, from_idx, count, {
            progress = on_progress,
            interval_seconds = 1.5,
        }, function(cached, total, failed, last_err)
            if not cancelled then cb(failed == 0, cached, last_err, total, failed) end
        end)
    end)
    return { cancel = function()
        cancelled = true
        if active then active.cancel() end
    end }
end

return Kuaikan
