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

--- 取消云端收藏，并清理本地章节缓存与登记。
---@param identity BookIdentity
---@param cb fun(ok: boolean, err: string|nil)
---@return table
function Source:deleteBookAsync(identity, cb)
    local cancelled, job = false, nil
    require("ui/network/manager"):runWhenOnline(function()
        if cancelled then return end
        job = self._client:detailAsync(identity.stable_id, function(wire, err)
            if cancelled then return end
            if not wire then
                cb(false, err or _("删除本书失败"))
                return
            end
            local comic_id = Mapper.comicId(wire)
            if not comic_id then
                cb(false, _("漫画详情解析失败"))
                return
            end
            job = self._client:setCollectAsync(comic_id, false, function(collect_wire, collect_err)
                if cancelled then return end
                if not collect_wire then
                    cb(false, collect_err or _("删除本书失败"))
                    return
                end
                local Paths = require("utils.paths")
                local Util = require("ffi/util")
                local dir = Paths.bookWorkDir(identity.stable_id, self.id)
                if require("libs/libkoreader-lfs").attributes(dir, "mode") == "directory"
                    and not Util.purgeDir(dir) then
                    cb(false, _("删除本书失败"))
                    return
                end
                os.remove(Paths.coverPath(identity.stable_id, self.id))
                require("db.book").remove(self.id, identity.stable_id)
                require("db.chapter").deleteUnder(dir)
                Toc.clear()
                self._covers[identity.stable_id] = nil
                cb(true)
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

--- 阅读中后台预取后续章节 CBZ。会话侧固定预取后面 3 章。
---@param identity BookIdentity
---@param toc BookChapter[]
---@param from_idx integer
---@param count integer
---@param cb fun()|nil
---@return { cancel: fun() }
function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.copymanga.chapter").prefetchAsync(
        self._client, identity, toc, from_idx, count, nil, cb
    )
end

--- 拉取云端浏览记录，用目录把 chapter_uuid 换成本地章序号。
--- 官方只有章粒度，没有页内坐标。
---@param identity BookIdentity
---@param cb fun(pos: ProgressPosition|nil, err: string|nil, meta: table|nil)
---@return { cancel: fun() }
function Source:getProgressAsync(identity, cb)
    if not require("source.copymanga.auth").hasSession() then
        cb(nil, nil, { empty = true })
        return { cancel = function() end }
    end
    local cancelled, toc_job
    local request = self._client:getProgressAsync(identity.stable_id, function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        local pos, uid = Mapper.progress(wire)
        if not pos or not uid then cb(nil, nil, { empty = true }); return end

        local function finish(idx)
            if not idx then cb(nil, nil, { empty = true }); return end
            pos.chapter_idx = idx
            pos.fraction = Toc.wholeFraction(
                identity.source_id, identity.stable_id, idx, pos.chapter_fraction
            ) or pos.fraction
            pos.extra = { chapter_uid = uid, chapter_idx = idx }
            cb(pos)
        end

        local idx = Toc.index(identity.source_id, identity.stable_id, uid)
        if idx then
            finish(idx)
            return
        end
        toc_job = self:loadTocAsync(identity, function(toc, toc_err)
            if cancelled then return end
            if not toc then cb(nil, toc_err); return end
            finish(Toc.index(identity.source_id, identity.stable_id, uid))
        end)
    end)
    return {
        cancel = function()
            cancelled = true
            if request and request.cancel then request.cancel() end
            if toc_job and toc_job.cancel then toc_job.cancel() end
        end,
    }
end

--- 推送当前章到云端。官方没有独立浏览写入接口；
--- 带 Token 的 chapter2 GET 就是打开章节时写入浏览记录的副作用。
---@param identity BookIdentity
---@param pos ProgressPosition|nil
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Source:putProgressAsync(identity, pos, cb)
    if not require("source.copymanga.auth").hasSession() then
        cb(nil, _("请先登录拷贝漫画账号"))
        return { cancel = function() end }
    end
    pos = pos or {}
    local cancelled, toc_job, push_job
    local chapter_idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx) or 1
    local extra = pos.extra
    local cached_uid = extra and tonumber(extra.chapter_idx) == chapter_idx
        and extra.chapter_uid or nil

    local function push(uid)
        if type(uid) ~= "string" or uid == "" then
            cb(nil, _("缺少章节信息"))
            return
        end
        push_job = self._client:chapterAsync(identity.stable_id, uid, function(wire, err)
            if cancelled then return end
            cb(wire and true or nil, err)
        end)
    end

    local function resolve()
        local uid = cached_uid or Toc.uid(identity.source_id, identity.stable_id, chapter_idx)
        if uid then
            push(uid)
            return
        end
        toc_job = self:loadTocAsync(identity, function(toc, err)
            if cancelled then return end
            if not toc then cb(nil, err); return end
            push(Toc.uid(identity.source_id, identity.stable_id, chapter_idx))
        end)
    end

    resolve()
    return {
        cancel = function()
            cancelled = true
            if toc_job and toc_job.cancel then toc_job.cancel() end
            if push_job and push_job.cancel then push_job.cancel() end
        end,
    }
end

--- 缓存整本漫画；已落盘章节自动跳过，章与章之间留间隔以免打爆接口。
---@param identity BookIdentity
---@param on_progress fun(done: integer, total: integer)|nil
---@param cb fun(ok: boolean, cached: integer, err: string|nil, total: integer, failed: integer)
---@return { cancel: fun() }
function Source:cacheAllChaptersAsync(identity, on_progress, cb)
    local cancelled, active = false, nil
    active = self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc then cb(false, 0, err or _("漫画目录为空"), 0, 0); return end
        active = require("source.copymanga.chapter").prefetchAsync(
            self._client, identity, toc, 0, #toc,
            {
                progress = on_progress,
                interval_seconds = 1.5,
            },
            function(cached, total, failed, last_err)
                if not cancelled then
                    cb(failed == 0, cached, last_err, total, failed)
                end
            end
        )
    end)
    return {
        cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end,
    }
end

return Copymanga
