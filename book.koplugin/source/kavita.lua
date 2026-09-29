local SourceBase = require("source.base")
local Client = require("source.kavita.client")
local Backfill = require("source.kavita.backfill")
local Anchor = require("source.kavita.anchor")
local JSON = require("json")
local _ = require("gettext")

local BACKFILL_STATE_FILE = "kavita-backfill.json"

--- 补全状态文件：seriesId → 已补过的 lastChapterAddedUtc（无值记 ""）。
---@return string
local function backfillStatePath()
    return require("utils.paths").root() .. "/" .. BACKFILL_STATE_FILE
end

---@param path string
---@return table
local function loadJson(path)
    local file = io.open(path, "r")
    if not file then return {} end
    local raw = file:read("*a")
    file:close()
    local ok, data = pcall(JSON.decode, raw or "")
    if ok and type(data) == "table" then return data end
    return {}
end

---@param path string
---@param data table
local function saveJson(path, data)
    local ok, encoded = pcall(JSON.encode, data)
    if not ok or type(encoded) ~= "string" then return end
    local tmp = path .. ".part"
    local file = io.open(tmp, "wb")
    if not file then return end
    local wrote = file:write(encoded)
    local closed = file:close()
    if not wrote or not closed then
        os.remove(tmp)
        return
    end
    os.rename(tmp, path)
end

---@return table<string, string>
local function loadBackfillState()
    return loadJson(backfillStatePath())
end

---@param state table<string, string>
local function saveBackfillState(state)
    saveJson(backfillStatePath(), state)
end

--- 注解幂等映射：`<workdir>/kavita-annotations.json`（键 = pos0）。
---@param workdir string
---@return string
local function annotationMapPath(workdir)
    return workdir .. "/kavita-annotations.json"
end

--- PersonDto[] → "a, b"；空/非表返回 nil。
---@param writers table|nil
---@return string|nil
local function writersToAuthors(writers)
    if type(writers) ~= "table" then return nil end
    local names = {}
    for _, person in ipairs(writers) do
        local name = type(person) == "table" and person.name or nil
        if type(name) == "string" and name ~= "" then
            names[#names + 1] = name
        end
    end
    if #names == 0 then return nil end
    return table.concat(names, ", ")
end

local DEFAULT_HEARTBEAT = 30

--- 当前章目录条目（identity.chapter_idx 或首章）；目录缺失返回 nil。
---@param identity BookIdentity
---@return BookChapter|nil
local function chapterEntry(identity)
    local list = require("source.toc").read(identity.source_id, identity.stable_id)
    if not list or #list == 0 then return nil end
    local idx = tonumber(identity.chapter_idx) or 1
    return list[idx] or list[1]
end

--- books.format（书籍源整本库用 epub/pdf，漫画库 cbz/image）。
---@param identity BookIdentity
---@return string|nil
local function bookFormat(identity)
    local book = identity.book
    if not book then
        book = require("db.book").get(identity.source_id, identity.stable_id)
    end
    return book and book.format
end

--- 漫画（format 0/1 → cbz/image）不参与 SourceUI 进度推送（kamare 自推）。
---@param identity BookIdentity
---@return boolean
local function isComic(identity)
    local format = bookFormat(identity)
    return format == "cbz" or format == "image"
end

--- KOReader xpointer → Kavita `//body/p[N]`；无法解析返回 nil。
---@param locator string|nil
---@return string|nil
local function scrollIdFromLocator(locator)
    if type(locator) ~= "string" then return nil end
    local n = locator:match("p%[(%d+)%]")
    if not n then return nil end
    return "//body/p[" .. n .. "]"
end

local Kavita = {}

local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

function Kavita.meta()
    return { id = "kavita", name = _("Kavita"), type = "book" }
end

function Kavita.new()
    local cfg = require("utils.settings").getSource("kavita")
    local meta = Kavita.meta()
    local self = setmetatable({
        id = meta.id,
        name = meta.name,
        type = meta.type,
        cfg = cfg,
        _client = Client:new(cfg),
    }, Source)
    return self
end

function Source:capabilities()
    return {
        search = true,
        refresh = true,
        scrape = false,
        edit = false,
        insight = true,
        stats_pull = false,
    }
end

function Source:configured()
    return self._client:configured()
end

function Source:coverRequest(identity)
    local stable_id = identity and identity.stable_id
    return self._client:coverRequest(stable_id)
end

function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    if opts.dirty_only then
        require("ui/uimanager"):nextTick(function()
            cb({
                pulled = 0, pushed = 0, hidden = 0, conflicts = 0,
                skipped = true, reason = "kavita dirty_only no-op",
            })
        end)
        return { cancel = function() end }
    end
    local libraries = self.cfg.libraries or {}
    local lib_ids = {}
    for id in pairs(libraries) do
        lib_ids[#lib_ids + 1] = id
    end
    if #lib_ids == 0 then
        require("ui/uimanager"):nextTick(function()
            cb({
                pulled = 0, pushed = 0, hidden = 0, conflicts = 0,
                skipped = true, reason = "kavita: no libraries selected",
            })
        end)
        return { cancel = function() end }
    end
    local all_books = {}
    local series_ts = {}
    local cancelled = false
    local pending = #lib_ids
    local has_error = false
    local function fetchLibrary(lib_id)
        local page = 1
        local function fetchPage()
            if cancelled then return end
            self._client:fetchSeriesPage(lib_id, page, 1000, function(data, err)
                if cancelled then return end
                if err then
                    if not has_error then
                        has_error = true
                        cb(nil, err)
                    end
                    return
                end
                if not data or #data == 0 then
                    pending = pending - 1
                    if pending == 0 and not has_error then
                        local Store = require("book.store")
                        local result, rerr = Store.reconcile(self.id, all_books)
                        if result then
                            self:_startBackfill(series_ts)
                            cb(result, rerr)
                        else
                            cb(nil, rerr)
                        end
                    end
                    return
                end
                for _, series in ipairs(data) do
                    series_ts[tostring(series.id)] = series.lastChapterAddedUtc or ""
                    all_books[#all_books + 1] = {
                        source_id = self.id,
                        stable_id = tostring(series.id),
                        title = series.name,
                        category = series.libraryName,
                        series = nil,
                        format = series.format == 3 and "epub" or series.format == 4 and "pdf" or series.format == 1 and "cbz" or series.format == 0 and "image" or nil,
                        cover = tostring(series.id),
                        deleted = 0,
                    }
                end
                page = page + 1
                fetchPage()
            end)
        end
        fetchPage()
    end
    for _, lib_id in ipairs(lib_ids) do
        fetchLibrary(lib_id)
    end
    return { cancel = function() cancelled = true end }
end

--- reconcile 完成后后台补全简介/作者；只补没见过的或 lastChapterAddedUtc 变过的。
--- 生命周期挂在源实例上，换源/失效时 Source:close 取消；再次同步会取消旧循环。
---@param series_ts table<string, string|nil>
function Source:_startBackfill(series_ts)
    if self._backfill then
        self._backfill:cancel()
        self._backfill = nil
    end
    if not self._client:configured() then return end
    local state = loadBackfillState()
    local items = Backfill.plan(series_ts, state)
    if #items == 0 then return end
    self._backfill = Backfill.new{
        fetch = function(item, cb)
            return self._client:fetchSeriesMetadataAsync(item.stable_id, cb)
        end,
        on_success = function(item, data)
            require("book.store").rememberMany({{
                source_id = self.id,
                stable_id = item.stable_id,
                intro = data.summary,
                authors = writersToAuthors(data.writers),
            }})
            state[item.stable_id] = item.ts
            saveBackfillState(state)
        end,
    }
    self._backfill:run(items)
end

--- 源实例失效/换源时取消后台补全。
function Source:close()
    if self._backfill then
        self._backfill:cancel()
        self._backfill = nil
    end
end

function Source:deleteBookAsync(identity, cb)
    local Store = require("book.store")
    if not Store.markDeleted(self.id, identity.stable_id) then
        require("ui/uimanager"):nextTick(function()
            cb(false, _("删除本书失败"))
        end)
        return { cancel = function() end }
    end
    require("ui/uimanager"):nextTick(function()
        cb(true)
    end)
    return { cancel = function() end }
end

function Source:openBookAsync(identity, opts, cb)
    opts = opts or {}
    local cancelled = false
    local dialog

    local function closeDialog()
        if dialog then dialog:close(); dialog = nil end
    end

    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        require("ui/uimanager"):nextTick(function()
            if not cancelled then cb(nil, _("网络不可用，请先连接 Wi-Fi")) end
        end)
        return { cancel = function() cancelled = true end }
    end

    local Paths = require("utils.paths")
    local stable_id = identity.stable_id
    local ext = "epub"
    local book_format = identity.book and identity.book.format
    if book_format == "pdf" then
        ext = "pdf"
    elseif book_format == "cbz" then
        ext = "cbz"
    end
    Paths.ensureBookWork(stable_id, self.id)
    local path = Paths.bookWorkDir(stable_id, self.id) .. "/1." .. ext
    local temp_path = path .. ".part"

    local function register(local_path)
        local ok, err = require("book.store").touch(local_path, identity)
        if ok then
            cb(local_path)
        else
            cb(nil, err)
        end
    end

    NetworkMgr:runWhenOnline(function()
        if cancelled then return end
        self:_resolveChapterId(identity, opts, function(chapter_id, resolve_err)
            if cancelled then return end
            if not chapter_id then
                cb(nil, resolve_err)
                return
            end
            local ProgressbarDialog = require("ui/widget/progressbardialog")
            dialog = ProgressbarDialog:new{
                title = _("正在下载…"),
                subtitle = identity.book and identity.book.title or stable_id,
                progress_max = 100,
                refresh_time_seconds = 1,
                dismissable = false,
            }
            dialog:show()

            self._client:downloadChapterAsync(chapter_id, temp_path, function(bytes, total)
                if dialog and total and total > 0 then
                    dialog:reportProgress(bytes * 100 / total)
                end
            end, function(ok, err)
                closeDialog()
                if cancelled then return end
                if not ok then
                    os.remove(temp_path)
                    cb(nil, err)
                    return
                end
                local file = io.open(temp_path, "rb")
                local head = file and file:read(4) or ""
                if file then file:close() end
                local valid = false
                if ext == "epub" then
                    valid = head == "PK\003\004" or head == "PK\005\006"
                elseif ext == "pdf" then
                    valid = head == "%PDF"
                else
                    valid = true
                end
                if not valid then
                    os.remove(temp_path)
                    cb(nil, _("下载文件校验失败"))
                    return
                end
                os.remove(path)
                if not os.rename(temp_path, path) then
                    os.remove(temp_path)
                    cb(nil, _("无法保存文件"))
                    return
                end
                register(path)
            end)
        end)
    end)

    return { cancel = function()
        cancelled = true
        closeDialog()
    end }
end

--- 下载用章 id：opts.chapter_id 优先，否则从目录取当前章/首章。
---@param identity BookIdentity
---@param opts { chapter_id?: string|number }|nil
---@param cb fun(chapter_id: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:_resolveChapterId(identity, opts, cb)
    if opts and opts.chapter_id then
        cb(tostring(opts.chapter_id))
        return { cancel = function() end }
    end
    return self:loadTocAsync(identity, function(toc, err)
        if not toc or #toc == 0 then
            cb(nil, err or _("章节列表为空"))
            return
        end
        local entry = toc[tonumber(identity.chapter_idx) or 1] or toc[1]
        cb(tostring(entry.chapterId or entry.uid))
    end)
end

--- 拉取 series 卷/章并写入 toc 缓存（含 chapterId/volumeId/libraryId/pages）。
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:_fetchTocAsync(identity, cb)
    local cancelled = false
    local job
    job = self._client:fetchSeriesAsync(identity.stable_id, function(series, err)
        if cancelled then return end
        if not series then cb(nil, err); return end
        job = self._client:fetchSeriesVolumesAsync(identity.stable_id, function(volumes, verr)
            if cancelled then return end
            if not volumes then cb(nil, verr); return end
            local list = {}
            for _, volume in ipairs(volumes) do
                for _, chapter in ipairs(volume.chapters or {}) do
                    list[#list + 1] = {
                        idx = #list + 1,
                        uid = tostring(chapter.id),
                        source_idx = tostring(chapter.id),
                        title = chapter.title or chapter.titleName or (volume.name or ""),
                        chapterId = chapter.id,
                        volumeId = volume.id or chapter.volumeId,
                        libraryId = series.libraryId,
                        pages = chapter.pages,
                    }
                end
            end
            if #list == 0 then cb(nil, _("章节列表为空")); return end
            if not require("source.toc").put(identity.source_id, identity.stable_id, list) then
                cb(nil, _("章节目录保存失败"))
                return
            end
            cb(list)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

--- 取目录：命中缓存直接回调，否则拉卷/章并写回。
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:loadTocAsync(identity, cb)
    local Toc = require("source.toc")
    local cached = Toc.read(identity.source_id, identity.stable_id)
    if cached and #cached > 0 then
        local cancelled = false
        require("ui/uimanager"):nextTick(function()
            if not cancelled then cb(cached) end
        end)
        return { cancel = function() cancelled = true end }
    end
    return self:_fetchTocAsync(identity, cb)
end

--- 强制刷新目录。
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:refreshTocAsync(identity, cb)
    require("source.toc").drop(identity.source_id, identity.stable_id)
    return self:_fetchTocAsync(identity, cb)
end

--- 拉远端进度（`GET /api/Reader/get-progress`）。漫画/无章元数据 → 空。
---@param identity BookIdentity
---@param cb fun(pos: ProgressPosition|nil, err: string|nil, meta: table|nil)
---@return { cancel: fun() }
function Source:getProgressAsync(identity, cb)
    if isComic(identity) then
        require("ui/uimanager"):nextTick(function() cb(nil, nil, { empty = true }) end)
        return { cancel = function() end }
    end
    local entry = chapterEntry(identity)
    if not entry or not entry.chapterId then
        require("ui/uimanager"):nextTick(function() cb(nil, nil, { empty = true }) end)
        return { cancel = function() end }
    end
    local cancelled = false
    local job = self._client:getProgressAsync(entry.chapterId, function(data, err, no_progress)
        if cancelled then return end
        if no_progress or not data then
            cb(nil, err, { empty = true })
            return
        end
        local pages = tonumber(entry.pages) or 0
        local page_num = tonumber(data.pageNum) or 0
        cb({
            fraction = require("book.progress").clampFraction(pages > 0 and (page_num / pages) or 0),
            page = page_num,
            total_pages = pages,
        })
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

--- 上报进度（`POST /api/Reader/progress`）；fraction≥1 再发 mark-chapter-read。
--- 章元数据缺失时降级只发 pageNum/bookScrollId。漫画跳过。
---@param identity BookIdentity
---@param pos ProgressPosition|nil
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Source:putProgressAsync(identity, pos, cb)
    pos = pos or {}
    if isComic(identity) then
        cb(true)
        return { cancel = function() end }
    end
    local entry = chapterEntry(identity)
    local frac = require("book.progress").clampFraction(pos.fraction)
    local pages = entry and tonumber(entry.pages) or 0
    local page_num = math.max(0, math.floor(frac * pages + 0.5))
    local series_id = tonumber(identity.stable_id) or identity.stable_id
    local payload = { pageNum = page_num }
    local scroll_id = scrollIdFromLocator(pos.locator)
    if scroll_id then payload.bookScrollId = scroll_id end
    if entry and entry.chapterId then
        payload.chapterId = entry.chapterId
        payload.volumeId = entry.volumeId
        payload.libraryId = entry.libraryId
        payload.seriesId = series_id
    end
    local cancelled = false
    local job = self._client:saveProgressAsync(payload, function(ok, err)
        if cancelled then return end
        if not ok then cb(nil, err); return end
        if frac >= 1 and entry and entry.chapterId then
            self._client:markChapterReadAsync({
                chapterId = entry.chapterId,
                seriesId = series_id,
                libraryId = entry.libraryId,
            }, function() end)
        end
        cb(true)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

--- 翻页心跳：heartbeat_interval 秒节流（0=关），只推位置变过的。
---@param payload { identity: BookIdentity, page: number|nil, total_pages: number|nil, percent: number|nil }
function Source:_onPageChanged(payload)
    if type(payload) ~= "table" or type(payload.identity) ~= "table" then return end
    if not self:configured() or isComic(payload.identity) then return end
    local interval = tonumber(self.cfg.heartbeat_interval)
    if interval == nil then interval = DEFAULT_HEARTBEAT end
    if interval <= 0 then return end
    local fraction = require("book.progress").clampFraction((tonumber(payload.percent) or 0) / 100)
    local page = tonumber(payload.page)
    local last = self._heartbeat
    if last and last.fraction == fraction and last.page == page then return end
    local now = os.time()
    if last and now - last.at < interval then return end
    self._heartbeat = { fraction = fraction, page = page, at = now }
    require("book.progress").recordHeartbeat(payload.identity, {
        fraction = fraction,
        page = page,
        total_pages = payload.total_pages,
    })
    self:syncProgressAsync({ identity = payload.identity, dirty_only = true }, function() end)
end

---@param event string
---@param payload table|nil
function Source:onEvent(event, payload)
    if event == "page_changed" then
        self:_onPageChanged(payload)
        return
    end
    return SourceBase.onEvent(self, event, payload)
end

--- 推送 EPUB 划线到 Kavita（`/api/Annotation/create`），逐条幂等建注解。
--- 非 EPUB / 缺章元数据跳过；单条失败只记日志，不阻塞本地落库。
---@param identity BookIdentity
---@param annotations table[]
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:pushNotesAsync(identity, annotations, cb)
    if type(identity) ~= "table" or type(identity.stable_id) ~= "string"
        or identity.stable_id == "" then
        cb(nil, _("无效的注解数据"))
        return nil
    end
    if not self:configured() then
        cb(nil, _("未配置服务器地址或 API Key"))
        return nil
    end
    if bookFormat(identity) ~= "epub" then
        cb(true)
        return nil
    end
    local entry = chapterEntry(identity)
    if not entry or not entry.chapterId then
        cb(true)
        return nil
    end
    local Paths = require("utils.paths")
    local workdir = Paths.bookWorkDir(identity.stable_id, self.id)
    local epub_path = (identity.book and identity.book.path) or (workdir .. "/1.epub")
    local map_path = annotationMapPath(workdir)
    local mapping = loadJson(map_path)
    local series_id = tonumber(identity.stable_id) or identity.stable_id

    local pending = {}
    for _, ann in ipairs(annotations or {}) do
        if type(ann) == "table" and ann.drawer
            and type(ann.pos0) == "string" and ann.pos0 ~= ""
            and not mapping[ann.pos0] then
            pending[#pending + 1] = ann
        end
    end
    if #pending == 0 then
        cb(true)
        return nil
    end

    local cancelled, index, current_job = false, 0, nil
    local function nextAnn()
        if cancelled then return end
        index = index + 1
        local ann = pending[index]
        if not ann then cb(true); return end
        local anchor = Anchor.compute(ann, epub_path)
        local page_number = anchor and anchor.pageNumber or Anchor.pageNumber(ann.pos0)
        local highlight_count = #(ann.text or "")
        if not page_number or highlight_count <= 0 then
            nextAnn()
            return
        end
        local xpath = anchor and anchor.xPath or ""
        local ending_xpath = anchor and anchor.endingXPath or ""
        current_job = self._client:createAnnotationAsync({
            chapterId = entry.chapterId,
            seriesId = series_id,
            volumeId = entry.volumeId,
            libraryId = entry.libraryId,
            ownerUserId = 0,
            xPath = xpath,
            endingXPath = ending_xpath,
            selectedText = ann.text or "",
            comment = ann.note or "",
            commentHtml = "",
            selectedSlotIndex = 0,
            pageNumber = page_number,
            highlightCount = highlight_count,
            containsSpoiler = false,
        }, function(data, err)
            current_job = nil
            if cancelled then return end
            if data then
                mapping[ann.pos0] = {
                    annotationId = data.id,
                    pageNumber = page_number,
                    xPath = xpath,
                    endingXPath = ending_xpath,
                }
                saveJson(map_path, mapping)
            else
                require("utils.log").warn("kavita annotation push failed", identity.stable_id, err)
            end
            nextAnn()
        end)
    end
    nextAnn()

    return { cancel = function()
        cancelled = true
        if current_job and current_job.cancel then current_job.cancel() end
    end }
end

return Kavita
