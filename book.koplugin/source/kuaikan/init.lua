--[[--
快看漫画数据源。

免费话不需要登录。登录后默认双向同步收藏与阅读进度。
一话是一组图片，打成 CBZ。

@module source.kuaikan
--]]

local Client = require("source.kuaikan.client")
local Mapper = require("source.kuaikan.mapper")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("l10n").get("source.kuaikan")

local Kuaikan = {}

---@return BookSourceMeta
function Kuaikan.meta()
    return SourceBase.loadMeta("kuaikan")
end

---@class KuaikanSource : SourceBase
local Source = setmetatable({ shelf_add = true }, { __index = SourceBase })
Source.__index = Source
local putProgressAsync

---@return KuaikanSource
function Kuaikan.new()
    local meta = Kuaikan.meta()
    return setmetatable({
        id = meta.id, name = meta.name, type = meta.type,
        putProgressAsync = Client.hasAccount() and putProgressAsync or nil,
    }, Source)
end

--- 未登录的收藏列表是空的，不能拿来对账。
---@return SourceCapabilities
function Source:capabilities()
    local caps = SourceBase.capabilities(self)
    caps.shelf_push = Client.hasAccount()
    return caps
end

---@return boolean
function Source:configured()
    return true
end

---@param opts { force?: boolean, dirty_only?: boolean, on_progress?: fun(text: string, done: integer|nil, total: integer|nil) }|nil
---@param cb fun(result: SyncResult|nil, err: string|nil)
---@return { cancel: fun() }
function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    local remote, pipeline = Client.newSync(false), nil
    if remote.cookie == "" then return SourceBase.skipped(cb, "not_logged_in") end
    remote:checkAsync(function(account, err)
        if remote.cancelled then return end
        if not account then cb(nil, err); return end
        local settings = require("utils.settings")
        local cfg = settings.getSource(self.id)
        if remote.user_id ~= account.user_id or cfg.logged_in ~= true then
            cfg.user_id, cfg.logged_in = account.user_id, true
            settings.saveSource(self.id)
            remote.user_id = account.user_id
        end
        remote.writing = true
        self.putProgressAsync = putProgressAsync
        local pending = true
        local job = require("source.shelf").syncAsync(self.id, remote, nil, opts, function(result, reason)
            pending, pipeline = false, nil
            if remote.cancelled then return end
            if not remote:current() then cb(nil, _("登录状态已变化，请重试")); return end
            if result and remote.push_error then
                if not opts.dirty_only then cb(nil, remote.push_error); return end
                result.push_error = remote.push_error
            end
            cb(result, reason)
        end)
        if pending then pipeline = job end
    end)
    return { cancel = function()
        remote:cancel()
        if pipeline then pipeline:cancel() end
    end }
end

---@param identity BookIdentity
---@param cb fun(pos: ProgressPosition|nil, err: string|nil, meta: table|nil)
function Source:getProgressAsync(identity, cb)
    local cfg = require("utils.settings").getSource(self.id)
    if not cfg.cookie or cfg.cookie == "" then return SourceBase.defer(cb, nil, nil, { empty = true }) end
    local remote, toc_job = Client.newSync(false), nil
    remote:checkAsync(function(account, err)
        if remote.cancelled then return end
        if not account then cb(nil, err); return end
        remote:historyAsync(identity.stable_id, function(comic_id, reason)
            if not comic_id then cb(nil, reason, not reason and { empty = true } or nil); return end
            local function load(force)
                local pending = true
                local job = self:loadTocAsync(identity, function(toc, toc_err)
                    pending, toc_job = false, nil
                    if remote.cancelled then return end
                    if not remote:current() then cb(nil, _("登录状态已变化，请重试")); return end
                    if not toc then cb(nil, toc_err); return end
                    for idx, chapter in ipairs(toc) do
                        if chapter.uid == comic_id then
                            cb({ chapter_idx = idx, chapter_title = chapter.title, fraction = (idx - 1) / #toc })
                            return
                        end
                    end
                    if not force then load(true); return end
                    cb(nil, _("快看云端章节不在当前目录中"))
                end, force)
                if pending then toc_job = job end
            end
            load(false)
        end)
    end)
    return { cancel = function()
        remote:cancel()
        if toc_job then toc_job:cancel() end
    end }
end

---@param self KuaikanSource
---@param identity BookIdentity
---@param pos ProgressPosition
---@param cb fun(ok: boolean|nil, err: string|nil)
putProgressAsync = function(self, identity, pos, cb)
    local remote, extra_job = Client.newSync(true), nil
    remote:checkAsync(function(account, err)
        if remote.cancelled then return end
        if not account then cb(nil, err); return end
        local pending = true
        local job = self:loadTocAsync(identity, function(toc, toc_err)
            pending, extra_job = false, nil
            if remote.cancelled then return end
            if not remote:current() then cb(nil, _("登录状态已变化，请重试")); return end
            if not toc then cb(nil, toc_err); return end
            local idx = pos.chapter_idx or identity.chapter_idx
            if not idx then idx = math.min(#toc, math.floor(pos.fraction * #toc) + 1) end
            if not toc[idx] then cb(nil, _("快看云端章节不在当前目录中")); return end
            local function report(count)
                if remote.cancelled then return end
                if not remote:current() then cb(nil, _("登录状态已变化，请重试")); return end
                local fraction = pos.chapter_fraction
                if not fraction then fraction = math.max(0, math.min(1, pos.fraction * #toc - (idx - 1))) end
                local record = Mapper.progressReport(identity.stable_id, toc[idx].uid, pos, fraction, count, os.time() * 1000)
                if not record then cb(nil, _("响应无效")); return end
                remote:reportProgressAsync(record, cb)
            end
            if pos.total_pages and pos.total_pages > 0 then report(pos.total_pages); return end
            local fetching = true
            local images_job = Client.imagesAsync(toc[idx].uid, function(urls, image_err)
                fetching, extra_job = false, nil
                if remote.cancelled then return end
                if not urls then cb(nil, image_err); return end
                report(#urls)
            end)
            if fetching then extra_job = images_job end
        end)
        if pending then extra_job = job end
    end)
    return { cancel = function()
        remote:cancel()
        if extra_job then extra_job:cancel() end
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
    local node, limit = Mapper.storeNode(opts and opts.node), opts and opts.limit or 60
    local cancelled, active = false, nil
    local loaded = false
    local first = Client.storeAsync(node, 1, function(books, err, more, groups)
        loaded = true
        if cancelled then return end
        active = nil
        if not books then cb(nil, err); return end
        local finished = false
        local pages = require("source.browse").pages(function(page, done)
            if page == 1 then done(books, nil, more); return end
            return Client.storeAsync(node, page, done)
        end, limit, groups, function(result, reason)
            finished, active = true, nil
            if cancelled then return end
            if result then
                for index = #result.data, limit + 1, -1 do result.data[index] = nil end
            end
            cb(result, reason)
        end)
        if not finished then active = pages end
    end)
    if not loaded then active = first end
    return { cancel = function()
        cancelled = true
        if active then active.cancel() end
    end }
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
        local loaded = false
        local toc_job = self:loadTocAsync(identity, function(fresh, err)
            loaded = true
            active = nil
            if cancelled then return end
            if not fresh then closeDialog(); cb(nil, err); return end
            local idx = startIndex(identity, opts, fresh)
            local materialized = false
            local chapter_job = Chapter.materializeAsync(identity, fresh[idx], function(done, total)
                if dialog and total > 0 then dialog:update(_("正在准备漫画…"), done, total) end
            end, function(path, materialize_err)
                materialized = true
                active = nil
                closeDialog()
                if cancelled then return end
                if not path then cb(nil, materialize_err); return end
                finish(path, idx)
            end)
            if not materialized then active = chapter_job end
        end)
        if not loaded then active = toc_job end
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
        cb({ items = items, pages = pages, title = _("话题页评论（首话）") })
    end)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.kuaikan.chapter").prefetchAsync(identity, toc, from_idx, count, nil, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    local cancelled, active = false, nil
    local loaded = false
    local toc_job = self:loadTocAsync(identity, function(toc, err)
        loaded = true
        active = nil
        if cancelled then return end
        if not toc then cb(false, 0, err, 0, 0); return end
        local from_idx, count = require("source.chapter").cacheRange(toc, range)
        local finished = false
        local cache_job = require("source.kuaikan.chapter").prefetchAsync(identity, toc, from_idx, count, {
            progress = on_progress,
            interval_seconds = 1.5,
        }, function(cached, total, failed, last_err)
            finished, active = true, nil
            if not cancelled then cb(failed == 0, cached, last_err, total, failed) end
        end)
        if not finished then active = cache_job end
    end)
    if not loaded then active = toc_job end
    return { cancel = function()
        cancelled = true
        if active then active.cancel() end
    end }
end

function Source:paragraphReviewsEnabled()
    return require("source.review_setting").enabled(self.id)
end

function Source:paragraphReviewPageAsync(identity, range, max_idx, cb)
    return require("book.review_cache").pageAsync(identity, range, max_idx, function(done)
        return require("source.with_chapter_uid").run(self, identity, _("目录为空"),
            function(uid, finish)
                return Client.commentPageAsync(uid, max_idx, function(items, err, _pages, page)
                    if not items then finish(nil, err); return end
                    for _idx, item in ipairs(items) do
                        if not item.id or item.id == "" or item.id == "0" then finish(nil, _("响应无效")); return end
                        item.content, item.replies = item.text, 0
                        item.time = item.time or ""
                    end
                    finish({ items = items, total = page.total, max_idx = page.max_idx, more = page.more })
                end)
            end, done)
    end, cb)
end

function Source:chapterReviewHotspotsAsync(identity, cb)
    return self:paragraphReviewPageAsync(identity, "chapter", 0, function(page, err)
        if not page then cb(nil, err); return end
        cb({ { range = "chapter", text = identity.book and identity.book.title or "",
            total = page.total, badge = tostring(page.total), heading = _("章节评论") } })
    end)
end

return Kuaikan
