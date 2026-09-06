--[[--
拷贝漫画数据源门面。

@module koplugin.book.source.copymanga
--]]

local Client = require("source.copymanga.client")
local Mapper = require("source.copymanga.mapper")
local SourceBase = require("source.base")
local Toc = require("source.copymanga.toc")
local _ = require("gettext")

local Copymanga = {}

---@return BookSourceMeta
function Copymanga.meta()
    return { id = "copymanga", name = _("拷贝漫画"), type = "chapter" }
end

---@class CopymangaSource : SourceBase
---@field _client CopymangaClient
---@field _covers table<string, string>
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return CopymangaSource
function Copymanga.new()
    local cfg = require("utils.settings").getSource("copymanga")
    local meta = Copymanga.meta()
    return setmetatable({
        id = meta.id,
        name = meta.name,
        type = meta.type,
        _client = Client:new(cfg),
        _covers = {},
    }, Source)
end

---@return SourceCapabilities
function Source:capabilities()
    return {
        search = true,
        refresh = false,
        scrape = false,
        edit = false,
        insight = true,
        stats_pull = false,
        store = true,
    }
end

---@return boolean
function Source:configured()
    return self._client:configured()
end

function Source:clearCaches()
    self._covers = {}
    Toc.clear()
end

function Source:close()
    self._covers = {}
end

---@param identity BookIdentity
---@return BookCoverRequest|nil, string|nil
function Source:coverRequest(identity)
    local url = self._covers[identity.stable_id] or (identity.book and identity.book.cover)
    if type(url) ~= "string" or not url:match("^https?://") then
        return nil, _("无封面")
    end
    return { url = url, headers = Client.headers(self._client.token) }
end

local function rememberCover(self, book)
    if book and book.cover then self._covers[book.stable_id] = book.cover end
end

---@param _opts table|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }
function Source:syncBooksAsync(_opts, cb)
    local Auth = require("source.copymanga.auth")
    if not Auth.hasSession() then
        return require("source.base").syncBooksAsync(self, _opts, cb)
    end
    local cancelled, job = false, nil
    job = self._client:collectAllAsync(function(wire, err)
        if cancelled then return end
        if not wire then
            cb(nil, err)
            return
        end
        local list = Mapper.collect(wire)
        for _, book in ipairs(list.data or {}) do
            rememberCover(self, book)
        end
        local result, rerr = require("book.store").reconcile(self.id, list.data or {})
        cb(result, rerr)
    end)
    return {
        cancel = function()
            cancelled = true
            if job and job.cancel then job.cancel() end
        end,
    }
end

---@param client CopymangaClient
---@param stable_id string
---@param groups table[]|nil
---@param cb fun(chapters: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }
local function loadChapters(client, stable_id, groups, cb)
    return client:chaptersAsync(stable_id, groups, function(rows, err)
        if not rows then cb(nil, err); return end
        local chapters = Mapper.chapters(rows)
        if not chapters then cb(nil, _("漫画目录为空")); return end
        cb(chapters)
    end)
end

function Source:listStoreAsync(opts, cb)
    opts = opts or {}
    local search = tostring(opts.search or "")
    local function on_wire(wire, err)
        if not wire then cb(nil, err); return end
        local result = Mapper.search(wire)
        for _, book in ipairs(result.data) do
            rememberCover(self, book)
        end
        cb(result)
    end
    if search ~= "" then
        return self._client:searchAsync(search, opts.page, opts.page_size, on_wire)
    end
    return self._client:discoverAsync(opts.page, opts.page_size, on_wire)
end

---@param identity BookIdentity
---@param cb fun(book: Book|nil, err: string|nil)
---@return { cancel: fun() }
function Source:getDetailAsync(identity, cb)
    local cancelled, job = false, nil
    job = self._client:detailAsync(identity.stable_id, function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        local book = Mapper.detail(identity.stable_id, wire)
        if not book then cb(nil, _("漫画详情解析失败")); return end
        local existing = require("db.book").get(self.id, identity.stable_id)
        if existing then
            book.percent = existing.percent
            book.in_library = existing.in_library
        end
        rememberCover(self, book)
        job = loadChapters(self._client, identity.stable_id, Mapper.groups(wire), function(chapters)
            if cancelled then return end
            if chapters then Toc.put(self.id, identity.stable_id, chapters) end
            require("book.store").rememberMany({ book })
            cb(book)
        end)
    end)
    return {
        cancel = function()
            cancelled = true
            if job and job.cancel then job.cancel() end
        end,
    }
end

---@param book Book|nil
---@param cb fun(ok: boolean|nil, err: string|nil, title: string|nil)
---@return { cancel: fun() }|nil
function Source:addStoreBookAsync(book, cb)
    if not require("source.copymanga.auth").hasSession() then
        cb(nil, _("请先登录拷贝漫画账号"))
        return nil
    end
    if not book or type(book.stable_id) ~= "string" or book.stable_id == "" then
        cb(nil, _("无效书籍"))
        return nil
    end
    local cancelled, job = false, nil
    job = self._client:detailAsync(book.stable_id, function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        local detail = Mapper.detail(book.stable_id, wire)
        local comic_id = Mapper.comicId(wire)
        if not detail or not comic_id then cb(nil, _("漫画详情解析失败")); return end
        job = self._client:setCollectAsync(comic_id, true, function(collect_wire, collect_err)
            if cancelled then return end
            if not collect_wire then cb(nil, collect_err); return end
            detail.in_library = true
            job = loadChapters(self._client, book.stable_id, Mapper.groups(wire), function(chapters, chapter_err)
                if cancelled then return end
                if not chapters then cb(nil, chapter_err); return end
                if not Toc.put(self.id, book.stable_id, chapters) then
                    cb(nil, _("漫画目录保存失败"))
                    return
                end
                require("book.store").rememberMany({ detail })
                rememberCover(self, detail)
                cb(true, nil, detail.title)
            end)
        end)
    end)
    return {
        cancel = function()
            cancelled = true
            if job and job.cancel then job.cancel() end
        end,
    }
end

---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:loadTocAsync(identity, cb)
    local cached = Toc.read(identity.source_id, identity.stable_id)
    if cached then
        require("ui/uimanager"):nextTick(function() cb(cached) end)
        return nil
    end
    local cancelled, job = false, nil
    job = self._client:detailAsync(identity.stable_id, function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        job = loadChapters(self._client, identity.stable_id, Mapper.groups(wire), function(chapters, chapter_err)
            if cancelled then return end
            if not chapters then cb(nil, chapter_err); return end
            if not Toc.put(identity.source_id, identity.stable_id, chapters) then
                cb(nil, _("漫画目录保存失败"))
                return
            end
            cb(chapters)
        end)
    end)
    return {
        cancel = function()
            cancelled = true
            if job and job.cancel then job.cancel() end
        end,
    }
end

---@param identity BookIdentity
---@param opts table|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:openBookAsync(identity, opts, cb)
    opts = opts or {}
    local cancelled, active, dialog = false, nil, nil

    local function closeDialog()
        if dialog then dialog:close(); dialog = nil end
    end

    require("ui/network/manager"):runWhenOnline(function()
        if cancelled then return end
        dialog = require("ui/widget/progressbardialog"):new{
            title = _("正在准备漫画…"),
            subtitle = identity.book and identity.book.title or identity.stable_id,
            progress_max = 100,
            refresh_time_seconds = 0.05,
            dismissable = false,
        }
        dialog:show()
        active = self:loadTocAsync(identity, function(toc, err)
            active = nil
            if cancelled then return end
            if not toc then closeDialog(); cb(nil, err); return end
            local idx = tonumber(opts.chapter_idx)
            if not idx then
                local pending = require("db.progress").get(identity.source_id, identity.stable_id)
                idx = pending and tonumber(pending.chapter_idx)
                if not idx and pending and tonumber(pending.fraction) then
                    idx = math.floor(tonumber(pending.fraction) * #toc) + 1
                end
            end
            idx = math.max(1, math.min(#toc, idx or 1))
            active = require("source.copymanga.chapter").materializeAsync(
                self._client, identity, toc[idx], idx,
                function(done, total)
                    if dialog and total > 0 then dialog:reportProgress(done * 100 / total) end
                end,
                function(path, materialize_err)
                    active = nil
                    closeDialog()
                    if cancelled then return end
                    if not path then cb(nil, materialize_err); return end
                    local ok, touch_err = require("book.store").touch(path, identity, {
                        chapter_idx = idx,
                        toc = toc,
                        book = identity.book,
                    })
                    cb(ok and path or nil, touch_err)
                end
            )
        end)
    end)

    return {
        cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
            closeDialog()
        end,
    }
end

return Copymanga
