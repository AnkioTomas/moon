local SourceBase = require("source.base")
local Client = require("source.kavita.client")
local Backfill = require("source.kavita.backfill")
local Anchor = require("source.kavita.anchor")
local Kamare = require("source.kavita.kamare")
local JSON = require("json")
local Text = require("utils.text")
local _ = require("gettext")
local T = require("ffi/util").template

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

--- 书架快照：上次成功对账的库集合 + 每本 series 的变更指纹。
--- 对账前比对，全无变化就跳过整表重写与首页重建（增量刷新）。
local SHELF_STATE_FILE = "kavita-shelf.json"

---@return string
local function shelfStatePath()
    return require("utils.paths").root() .. "/" .. SHELF_STATE_FILE
end

--- 单本 series 的变更指纹：展示字段 + 漫画进度字段，任一变化都需要重跑对账/回填。
--- 进度字段只对漫画（Archive/Image）生效——书籍进度走本地 pending_progress，
--- 若把书籍 pagesRead 也算进指纹，读完一次就会让整个书架快照失效。
---@param series table
---@return string
local function seriesFingerprint(series)
    local parts = {
        tostring(series.lastChapterAddedUtc or ""),
        tostring(series.name or ""),
        tostring(series.format or ""),
        tostring(series.pages or 0),
    }
    local fmt = tostring(series.format or "")
    if fmt == "0" or fmt == "1" then
        parts[#parts + 1] = tostring(series.pagesRead or 0)
        parts[#parts + 1] = tostring(series.latestReadDate or "")
    end
    return table.concat(parts, "\31")
end

--- 两个 id 列表是否同集合（忽略顺序）。
---@param a table|nil
---@param b table
---@return boolean
local function sameIdSet(a, b)
    if type(a) ~= "table" or #a ~= #b then return false end
    local set = {}
    for _, v in ipairs(a) do set[tostring(v)] = true end
    for _, v in ipairs(b) do
        if not set[tostring(v)] then return false end
    end
    return true
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

--- 补全状态落盘节流：整份 JSON 重写，逐条落盘会随条目增长变成 O(n²)（越到后面越慢）。
local BACKFILL_SAVE_INTERVAL = 10

--- 册行 stable_id = ``seriesId:chapterId``；容器/单册不带分隔。
---@param stable_id string|nil
---@return string|nil series_id
---@return string|nil chapter_id
local function splitVolumeStable(stable_id)
    local series, chapter = tostring(stable_id or ""):match("^(%d+):(%d+)$")
    return series, chapter
end

---@param series_id string|number
---@param chapter_id string|number
---@return string
local function volumeStableId(series_id, chapter_id)
    return tostring(series_id) .. ":" .. tostring(chapter_id)
end

--- 取 Kavita seriesId：容器即 stable_id；册行从 ``seriesId:chapterId`` 解析。
---@param stable_id string|nil
---@return number|string|nil
local function seriesIdOf(stable_id)
    local series = splitVolumeStable(stable_id)
    if series then return tonumber(series) or series end
    return tonumber(stable_id) or stable_id
end

--- 当前章目录条目（identity.chapter_idx 或首章）；目录缺失返回 nil。
--- 册行目录是静态单条，不走 TTL；容器目录（多册/旧章节模式）走 source.toc 缓存。
---@param identity BookIdentity
---@return BookChapter|nil
local function chapterEntry(identity)
    local list
    if splitVolumeStable(identity.stable_id) then
        list = require("book.store").toc(identity)
    else
        list = require("source.toc").read(identity.source_id, identity.stable_id)
    end
    if not list or #list == 0 then return nil end
    local idx = tonumber(identity.chapter_idx) or 1
    return list[idx] or list[1]
end

local FORMAT_NAMES = { [0] = "image", [1] = "cbz", [3] = "epub", [4] = "pdf" }

--- Kavita 数字格式 → 领域名（0 image / 1 cbz / 3 epub / 4 pdf）。
---@param n string|number|nil
---@return string|nil
local function formatName(n)
    return FORMAT_NAMES[tonumber(n)]
end

--- Kavita ISO 时间（``2026-09-29T20:07:19.193``）→ epoch；无法解析返回 0。
--- 仅用于「最近阅读」排序，时区偏差不影响相对顺序。
---@param s string|nil
---@return integer
local function parseUtcIso(s)
    if type(s) ~= "string" then return 0 end
    local y, mo, d, h, mi, se = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if not y then return 0 end
    return os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(se),
    }) or 0
end

--- On Deck SeriesDto[] → 首页展示用 Book[]：书籍与漫画都保留（漫画由 kamare 在线读）。
--- 进度取 series 级 pagesRead/pages；格式未知或 id 缺失的脏行跳过。
---@param source_id string
---@param series table[]
---@return Book[]
local function onDeckBooks(source_id, series)
    local books = {}
    for _, s in ipairs(series or {}) do
        local fmt = formatName(s.format)
        if fmt ~= nil and s.id ~= nil then
            local total = tonumber(s.pages) or 0
            local read = tonumber(s.pagesRead) or 0
            local percent = 0
            if total > 0 then
                percent = math.floor(read * 100 / total + 0.5)
                if percent > 100 then percent = 100 end
            end
            books[#books + 1] = {
                source_id = source_id,
                stable_id = tostring(s.id),
                title = s.name,
                format = fmt,
                percent = percent,
            }
        end
    end
    return books
end

--- 目录缓存格式版本：标题抽取逻辑变化时 +1，旧目录按过期重建。
--- v2：章元数据缺失时不再用纯数字卷号，退回文件名（漫画）。
--- v3：带 pagesRead，供选册预选/标「在读·已读」，也供最近阅读显示当前卷。
local TOC_VERSION = 3

--- 清洗 Kavita 标题：去空白；`-100000`（number 哨兵）与纯负数标题视为未命名。
---@param value any
---@return string|nil
local function cleanTitle(value)
    if type(value) ~= "string" then return nil end
    local s = Text.trim(value)
    if s == "" or s:match("^%-%d+$") then return nil end
    return s
end

--- 卷名当标题用：纯数字卷号（``"1"``）不是名称，返回 nil 让位给文件名。
---@param value any
---@return string|nil
local function volumeNameTitle(value)
    local name = cleanTitle(value)
    if name and name:match("^%d+$") then return nil end
    return name
end

--- 章节文件末段（去扩展名）；无文件信息返回 nil。
---@param chapter table
---@return string|nil
local function chapterFileName(chapter)
    local file_path = chapter.files and chapter.files[1] and chapter.files[1].filePath
    if type(file_path) ~= "string" or file_path == "" then return nil end
    return Text.basename(file_path):gsub("%.[^%.]+$", "")
end

--- 章节展示标题：优先章元数据（titleName/title），其次有意义的卷名，最后文件名。
--- 书籍（EPUB/PDF）章元数据齐全；漫画在 Kavita 侧无章元数据（title 恒为
--- `-100000` 哨兵、卷名恒为数字卷号）→ 落到文件名（如 `AKIRA Vol.01`）。
---@param chapter table
---@param volume table
---@return string|nil
local function chapterDisplayTitle(chapter, volume)
    return cleanTitle(chapter.titleName)
        or cleanTitle(chapter.title)
        or volumeNameTitle(volume and volume.name)
        or cleanTitle(chapterFileName(chapter))
end

--- books.format：优先身份书行，其次 toc 条目（books 表没有 format 列）。
---@param identity BookIdentity
---@return string|nil
local function bookFormat(identity)
    local book = identity.book
    if book and book.format then return book.format end
    local entry = chapterEntry(identity)
    if entry and entry.format then return entry.format end
    if not book then
        book = require("db.book").get(identity.source_id, identity.stable_id)
    end
    return book and book.format
end

--- 本地 epub 物理路径；未下载/未登记返回 nil。
--- 用于把 Kavita 网页端进度里的 `id("...")` bookScrollId 解析成 spine 内位置。
---@param identity BookIdentity
---@return string|nil
local function bookFilePath(identity)
    local book = identity.book
    if not (book and type(book.path) == "string" and book.path ~= "") then
        book = require("db.book").get(identity.source_id, identity.stable_id) or book
    end
    local path = book and book.path
    if type(path) == "string" and path ~= "" then return path end
    return nil
end

--- 漫画（format 0/1 → cbz/image）不参与 SourceUI 进度推送（kamare 自推）。
---@param identity BookIdentity
---@return boolean
local function isComic(identity)
    local format = bookFormat(identity)
    return format == "cbz" or format == "image"
end

--- Kavita 进度是 spine 页级：`pageNum` 是 0-based spine 序号、`pages` 是 spine 数
--- （EPUB 实测与 `<spine>` 条目数一一对应）。KOReader 的 `DocFragment[D]` 就是
--- spine `D-1`（注解锚点已钉死），因此 pageNum 取 xpointer 的 spine，而不是
--- 「内容比例 × 页数」——后者会因各 spine 长度悬殊而漂移。
---@param pos ProgressPosition
---@param pages integer
---@param frac number 章内/spine 内比例（无 locator 时的回退依据）
---@return integer
local function pageNumOf(pos, pages, frac)
    frac = require("book.progress").clampFraction(frac)
    local spine = Anchor.pageNumber(pos.locator)
    if spine and pages > 0 then
        if spine < 0 then spine = 0 elseif spine > pages - 1 then spine = pages - 1 end
        -- Kavita 用 pageNum == pages 表示「已读完」；最后一屏读完时发 pages。
        if frac >= 1 and spine == pages - 1 then return pages end
        return spine
    end
    local estimate = math.floor(frac * pages + 0.5)
    -- 没有 locator 时用比例估算，但绝不能在真正读完前凑到 pages：
    -- Kavita 把 pageNum == pages 当「本章已读完」，提前到达会把书从「正在阅读」移除。
    if frac < 1 and estimate >= pages then estimate = pages - 1 end
    if estimate < 0 then estimate = 0 end
    return estimate
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

--- 首页「Kavita 最近阅读」：服务端 On Deck 列表，书籍与漫画都保留
--- （漫画由 kamare 在线读，进度也由 kamare 推给 Kavita）。
--- 不落本地库；未配置时异步回错误，调用方显示空态。
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Source:onDeckAsync(cb)
    if not self:configured() then
        require("ui/uimanager"):nextTick(function()
            cb(nil, _("未配置服务器地址或 API Key"))
        end)
        return { cancel = function() end }
    end
    local cancelled = false
    local job = self._client:onDeckAsync(function(data, err)
        if cancelled then return end
        if not data then cb(nil, err); return end
        cb(onDeckBooks(self.id, data))
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

function Source:coverRequest(identity)
    local stable_id = identity and identity.stable_id
    -- 册行的 stable_id 是 `seriesId:chapterId`，封面仍取 series 的。
    return self._client:coverRequest(seriesIdOf(stable_id))
end

function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    local started_at = os.time()
    --- 刷新耗时埋点：正常走 dbg，≥3s 升 warn（无需开调试模式也能排查慢刷新）。
    local function shelfLog(msg, ...)
        local elapsed = os.time() - started_at
        local logger = require("utils.log")
        if elapsed >= 3 then
            logger.warn(msg, elapsed .. "s", ...)
        else
            logger.dbg(msg, elapsed .. "s", ...)
        end
    end
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
    local series_fp = {}
    local comic_progress = {}
    local cancelled = false
    local pending = #lib_ids
    local has_error = false
    local PAGE_SIZE = 1000
    -- 每库一次并行取 2 页：整库列表拉取从「页数 × RTT」压到「ceil(页数/2) × RTT」。
    local PAGE_STRIDE = 2

    --- 收下一条 series：骨架行 + 指纹 + 漫画进度。
    ---@param series table
    local function addSeries(series)
        series_ts[tostring(series.id)] = series.lastChapterAddedUtc or ""
        series_fp[tostring(series.id)] = seriesFingerprint(series)
        local fmt = formatName(series.format)
        all_books[#all_books + 1] = {
            source_id = self.id,
            stable_id = tostring(series.id),
            title = series.name,
            category = series.libraryName,
            series = nil,
            format = fmt,
            cover = tostring(series.id),
            deleted = 0,
        }
        -- 漫画进度回填：series 级 pagesRead/pages 即 Kavita 的阅读比例
        -- （与「Kavita 最近阅读」On Deck 用的一致），写进 pending_progress
        -- 供书架/最近阅读跨设备显示；sync_status=1 不回推，updated_at 取服务端。
        if (fmt == "cbz" or fmt == "image") and series.id ~= nil then
            local pages = tonumber(series.pages) or 0
            local read = tonumber(series.pagesRead) or 0
            if pages > 0 and read > 0 then
                comic_progress[#comic_progress + 1] = {
                    stable_id = tostring(series.id),
                    fraction = math.min(1, read / pages),
                    page = read,
                    total_pages = pages,
                    updated_at = parseUtcIso(series.latestReadDate),
                }
            end
        end
    end

    --- 全部库拉完：增量判定 → 对账 → 回调。
    local function finishFetch()
        local Store = require("book.store")
        shelfLog("kavita.shelf fetched", #all_books, "series")
        -- 增量判定：库集合 + 每本指纹都一致，且本地书架集合与远端一致 → 跳过对账。
        local prev = loadJson(shelfStatePath())
        local prev_series = type(prev.series) == "table" and prev.series or nil
        local changed, changed_ids = false, nil
        if not prev_series or not sameIdSet(prev.libs, lib_ids) then
            changed = true
        else
            changed_ids = {}
            for id, fp in pairs(series_fp) do
                if prev_series[id] ~= fp then
                    changed = true
                    changed_ids[id] = true
                end
            end
            for id in pairs(prev_series) do
                if series_fp[id] == nil then
                    changed = true
                    changed_ids[id] = true
                end
            end
            -- 本地书架自校验：与「上次对账后的本地数量」比对，而不是远端数量——
            -- 本地软删的墓碑仍在远端集合里，拿远端数量比会永远不相等、每次刷新都全量。
            if not changed and type(Store.shelfStableIds) == "function" then
                local local_ids = Store.shelfStableIds(self.id)
                if type(local_ids) ~= "table" or #local_ids ~= tonumber(prev.local_count) then
                    changed, changed_ids = true, nil
                end
            elseif not changed then
                changed, changed_ids = true, nil -- 无法校验本地集合 → 稳妥走全量
            end
        end
        if not changed then
            -- 远端书架没变，但本地进度可能刚变（关书落 pending_progress）。不能当 skipped：
            -- 调用方要据此重建书架视图并广播 shelf_changed，让首页/书库卡片重读本地进度。
            shelfLog("kavita.shelf sync unchanged", #all_books, "series")
            cb({
                pulled = 0, pushed = 0, hidden = 0, conflicts = 0,
                skipped = false, unchanged = true,
            })
            return
        end
        -- 漫画进度只回填本次变更的 series（首次/库变更时 changed_ids=nil → 全量）。
        local comics = comic_progress
        if changed_ids ~= nil then
            comics = {}
            for _, row in ipairs(comic_progress) do
                if changed_ids[row.stable_id] then comics[#comics + 1] = row end
            end
        end
        local result, rerr
        if changed_ids ~= nil and type(Store.reconcileDelta) == "function" then
            -- 只写变更/新增行、只软删消失行，未变的行不重写。
            local changed_rows = {}
            for _, b in ipairs(all_books) do
                if changed_ids[b.stable_id] then
                    changed_rows[#changed_rows + 1] = b
                end
            end
            local removed_ids = {}
            for id in pairs(prev_series) do
                if series_fp[id] == nil then removed_ids[#removed_ids + 1] = id end
            end
            result, rerr = Store.reconcileDelta(self.id, changed_rows, removed_ids)
        else
            result, rerr = Store.reconcile(self.id, all_books)
        end
        if result then
            self:_backfillComicProgress(comics)
            self:_startBackfill(series_ts)
            -- 记下对账后的本地书架数量，供下次增量判定（含本地软删，故不等于远端数量）。
            local local_count
            if type(Store.shelfStableIds) == "function" then
                local ids = Store.shelfStableIds(self.id)
                if type(ids) == "table" then local_count = #ids end
            end
            saveJson(shelfStatePath(), {
                libs = lib_ids, series = series_fp, local_count = local_count,
            })
            shelfLog("kavita.shelf sync done", "pulled", result.pulled,
                "hidden", result.hidden, "of", #all_books)
            cb(result, rerr)
        else
            cb(nil, rerr)
        end
    end

    local function fetchLibrary(lib_id)
        local finished = false
        local function finishLibrary()
            if finished then return end
            finished = true
            pending = pending - 1
            if pending == 0 and not has_error then finishFetch() end
        end
        --- 并行取 [from, from+count-1]；整组都满页才继续下一组，否则本库结束。
        local function fetchGroup(from, count, on_full)
            if cancelled or finished then return end
            local remaining, full_pages = count, 0
            local errored = false
            for p = from, from + count - 1 do
                self._client:fetchSeriesPage(lib_id, p, PAGE_SIZE, function(data, err)
                    if cancelled or finished then return end
                    remaining = remaining - 1
                    if err then
                        errored = true
                        if not has_error then
                            has_error = true
                            cb(nil, err)
                        end
                    elseif data and #data > 0 then
                        for _, series in ipairs(data) do addSeries(series) end
                        if #data >= PAGE_SIZE then full_pages = full_pages + 1 end
                    end
                    if remaining == 0 and not errored then
                        if full_pages == count then on_full() else finishLibrary() end
                    end
                end)
            end
        end
        local fetchPair
        fetchPair = function(from)
            fetchGroup(from, PAGE_STRIDE, function() fetchPair(from + PAGE_STRIDE) end)
        end
        -- 首屏单独取：小库（≤1 页）只发一次请求；满页再按 2 页一组并行。
        fetchGroup(1, 1, function() fetchPair(2) end)
    end
    for _, lib_id in ipairs(lib_ids) do
        fetchLibrary(lib_id)
    end
    return { cancel = function() cancelled = true end }
end

--- 漫画进度回填：把书架同步拿到的 series 级 pagesRead/pages 写进 pending_progress，
--- 让书架/最近阅读在换设备或重装后仍显示服务端进度。干净行（sync_status=1）不回推。
---@param rows { stable_id: string, fraction: number, page: integer, total_pages: integer, updated_at: integer }[]
function Source:_backfillComicProgress(rows)
    if type(rows) ~= "table" or #rows == 0 then return end
    local ProgressDB = require("db.progress")
    for _, row in ipairs(rows) do
        -- 显式取局部量，避免闭包捕获循环变量（continue-point 回调异步执行）。
        local series_id = row.stable_id
        local fraction, page, total_pages, updated_at = row.fraction, row.page, row.total_pages, row.updated_at
        ProgressDB.upsertRemote(self.id, series_id, {
            fraction = fraction,
            page = page,
            total_pages = total_pages,
            updated_at = updated_at,
        })
        -- 再拉「继续阅读点」补当前章/卷标题，最近阅读才能显示"看到第几卷"（跨设备也准）。
        if type(self._client.continuePointAsync) == "function" then
            self._client:continuePointAsync(series_id, function(chapter)
                if type(chapter) ~= "table" or chapter.id == nil then return end
                local title = chapterDisplayTitle(chapter, nil)
                if not title then return end
                ProgressDB.upsertRemote(self.id, series_id, {
                    fraction = fraction,
                    page = page,
                    total_pages = total_pages,
                    updated_at = updated_at,
                    chapter_title = title,
                })
            end)
        end
    end
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
    -- 状态文件整份重写，逐条存会随条目增长越写越慢；节流到 10s 一次，跑完再落一次。
    local dirty, last_save = false, 0
    local function persist(force)
        if not dirty then return end
        local now = os.time()
        if not force and now - last_save < BACKFILL_SAVE_INTERVAL then return end
        saveBackfillState(state)
        dirty, last_save = false, now
    end
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
            dirty = true
            persist(false)
        end,
        on_done = function() persist(true) end,
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

--- identity 已下载的容器整本文件名 ``<idx>.<ext>``（旧模型兼容，用于预选）。
---@param identity BookIdentity
---@return integer|nil
local function downloadedChapterIdx(identity)
    local path = identity.book and identity.book.path
    if type(path) ~= "string" then return nil end
    local name = path:match("([^/]+)$")
    return name and tonumber(name:match("^(%d+)%.")) or nil
end

--- 选册列表项标题：清洗后的章标题/卷名/文件名，最后“第 N 卷”。
---@param entry BookChapter|table
---@return string
local function chapterLabel(entry)
    local title = cleanTitle(entry.title)
        or volumeNameTitle(entry.volume_name)
        or cleanTitle(entry.file_name)
    if title then return title end
    return T(_("第 %1 卷"), tostring(entry.idx or ""))
end

--- 选册预选：优先「在读」（0<pagesRead<pages）的最后一册；否则第一册未读；否则 nil。
--- 旧目录没有 pagesRead → 返回 nil，调用方回退原逻辑。
---@param toc table[]
---@return integer|nil
local function readingChapterIdx(toc)
    local in_progress, first_unread
    for i = 1, #toc do
        local pages = tonumber(toc[i].pages) or 0
        local read = tonumber(toc[i].pagesRead) or 0
        if read > 0 and (pages == 0 or read < pages) then in_progress = i end
        if first_unread == nil and (pages == 0 or read < pages) then first_unread = i end
    end
    return in_progress or first_unread
end

--- 打开书籍：单册 series 整本打开（原生目录）；多册 series 弹选册，
--- 选中后把该册物化成独立册行（``seriesId:chapterId``）并以整书模式打开，
--- 从而每册有自己的书目、原生目录与进度。已下载册文件直接复用。
---@param identity BookIdentity
---@param opts { chapter_idx?: number|string, chapter_id?: number|string }|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:openBookAsync(identity, opts, cb)
    opts = opts or {}
    local cancelled = false
    local dialog
    local picker

    local function closeDialog()
        if dialog then dialog:close(); dialog = nil end
    end
    local function closePicker()
        if picker then
            require("ui/uimanager"):close(picker)
            picker = nil
        end
    end
    --- 结束本次打开；取消后一律不回调。``opts.handled`` 表示源已自行接管
    --- （漫画交给 kamare 阅读器），open.lua 据此跳过 ReaderUI。
    ---@param path string|nil
    ---@param err string|nil
    ---@param opts table|nil
    local function finish(path, err, opts)
        if cancelled then return end
        closeDialog()
        if path then cb(path) else cb(nil, err, opts) end
    end

    local Paths = require("utils.paths")
    local Store = require("book.store")
    local Toc = require("source.toc")

    ---@param path string
    ---@return boolean
    local function fileExists(path)
        local file = io.open(path, "rb")
        if file then file:close(); return true end
        return false
    end

    --- 下载/复用某一册到 target_stable 的工作目录，登记后回调。
    ---@param entry BookChapter|table
    ---@param target_stable string 承载该册的 books.stable_id
    ---@param target_identity BookIdentity
    local function downloadEntry(entry, target_stable, target_identity)
        local ext = (entry and entry.format) or "epub"
        local path = Paths.bookWorkDir(target_stable, self.id) .. "/1." .. ext
        if fileExists(path) then
            local ok, err = Store.touch(path, target_identity)
            if not ok then finish(nil, err); return end
            finish(path)
            return
        end
        if not require("ui/network/manager"):isOnline() then
            finish(nil, _("网络不可用，请先连接 Wi-Fi"))
            return
        end

        Paths.ensureBookWork(target_stable, self.id)
        local temp_path = path .. ".part"
        local ProgressbarDialog = require("ui/widget/progressbardialog")
        dialog = ProgressbarDialog:new{
            title = _("正在下载…"),
            subtitle = (entry and entry.title)
                or (identity.book and identity.book.title) or target_stable,
            progress_max = 100,
            refresh_time_seconds = 1,
            dismissable = false,
        }
        dialog:show()

        self._client:downloadChapterAsync(entry.chapterId or entry.uid, temp_path, function(bytes, total)
            if dialog and total and total > 0 then
                dialog:reportProgress(bytes * 100 / total)
            end
        end, function(ok, err)
            closeDialog()
            if cancelled then return end
            if not ok then
                os.remove(temp_path)
                finish(nil, err)
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
                finish(nil, _("下载文件校验失败"))
                return
            end
            os.remove(path)
            if not os.rename(temp_path, path) then
                os.remove(temp_path)
                finish(nil, _("无法保存文件"))
                return
            end
            local touched, touch_err = Store.touch(path, target_identity)
            if not touched then finish(nil, touch_err); return end
            finish(path)
        end)
    end

    --- 漫画条目？（cbz / image 走 kamare 在线阅读，不下载。）
    ---@param entry table|nil
    ---@return boolean
    local function isComicEntry(entry)
        local f = entry and entry.format
        return f == "cbz" or f == "image"
    end

    --- kamare 打开失败后的原生回落：下载 cbz 交内置阅读器打开（image 无原生可读，维持报错）。
    ---@param entry table
    ---@param target_stable string 承载该册的 books.stable_id
    ---@param target_identity BookIdentity
    ---@param cause string|nil kamare 侧错误信息
    local function downloadNativeFallback(entry, target_stable, target_identity, cause)
        if (entry and entry.format) ~= "cbz" then
            finish(nil, cause or _("打开漫画失败"))
            return
        end
        require("utils.log").warn("kavita.kamare fallback to native", cause or "")
        downloadEntry(entry, target_stable, target_identity)
    end

    --- 漫画：交给外部 kamare 阅读器在线阅读；成功即「源已自行接管」。
    ---@param entry table
    ---@param series_toc table[] 本 series 章列表（章末续章按此顺序找下一章）
    ---@param on_fail fun(err: string|nil)|nil kamare 打开失败时的回落；nil 则直接上报错误
    local function launchKamare(entry, series_toc, on_fail)
        -- 漫画是在线流式阅读，离线无法打开：给友好提示，别把 kamare 拉起来再报错。
        if not require("ui/network/manager"):isOnline() then
            finish(nil, _("网络不可用，请先连接 Wi-Fi"))
            return
        end
        local series_name = identity.book and identity.book.title
        series_toc = series_toc or { entry }

        --- 关书回写：kamare 已把进度推给 Kavita，这里本地补一条干净（sync_status=1）
        --- 行并刷新桌面，让书架立刻反映新位置（远端拉取见工单 06）。
        ---@param e table 当前打开的册
        local function onKamareClose(e, current_page, total_pages)
            local ok, err = pcall(function()
                local count = #series_toc
                if count < 1 then count = 1 end
                local idx = 1
                for i = 1, #series_toc do
                    if series_toc[i] == e then idx = i; break end
                end
                local total = tonumber(total_pages) or tonumber(e.pages) or 0
                local page = tonumber(current_page) or 1
                local chapter_fraction = total > 0 and math.min(1, math.max(0, page / total)) or 0
                require("db.progress").upsertRemote(self.id, identity.stable_id, {
                    fraction = ((idx - 1) + chapter_fraction) / count,
                    chapter_idx = idx,
                    chapter_title = chapterLabel(e),
                    chapter_fraction = chapter_fraction,
                    page = page,
                    total_pages = total,
                    updated_at = os.time(),
                })
                local fm_ok, FileManager = pcall(require, "apps/filemanager/filemanager")
                local plugin = fm_ok and FileManager.instance and FileManager.instance.book
                local desktop = plugin and plugin.desktop
                if desktop and type(desktop.updateView) == "function" then
                    desktop:updateView()
                    require("ui/uimanager"):setDirty(desktop, "ui")
                end
            end)
            if not ok then
                require("utils.log").warn("kavita.kamare on_close failed", err)
            end
        end

        --- 打开一册：先拉该章云端进度算出续读页，再交给 kamare。
        --- kamare 独立运行时由浏览页把 chapter.pagesRead 换算成 startPage；
        --- moon 自己拉起时必须补这一步，否则每次从第 1 页开始。
        ---@param e table
        ---@param on_done fun(viewer: table|nil, err: string|nil)
        local function openChapter(e, on_done)
            local started = false
            local function launch(start_page)
                if started then return end
                started = true
                -- kamare 是外部非公开契约：整体 pcall，抛错也回落到 on_fail（原生下载）。
                local ok, viewer, err = pcall(Kamare.open, {
                    chapter = e,
                    title = series_name,
                    start_page = start_page,
                    on_close = function(current_page, total_pages)
                        onKamareClose(e, current_page, total_pages)
                    end,
                    on_next_chapter = function(next_id)
                        for _, cand in ipairs(series_toc) do
                            if tostring(cand.chapterId or cand.uid) == tostring(next_id) then
                                openChapter(cand, function(v, oerr)
                                    if not v then
                                        require("utils.log").warn("kavita.kamare next chapter failed", oerr)
                                    end
                                end)
                                return
                            end
                        end
                    end,
                })
                if not ok then viewer, err = nil, tostring(viewer) end
                on_done(viewer, err)
            end

            if e.chapterId == nil then
                launch(1)
                return
            end
            local job = self._client:getProgressAsync(e.chapterId, function(data)
                local start_page = 1
                local pages_read = data and tonumber(data.pageNum)
                local pages = tonumber(e.pages) or 0
                if pages_read and pages_read >= 0 then
                    start_page = pages_read + 1
                    if pages > 0 and start_page > pages then start_page = pages end
                end
                launch(start_page)
            end)
            if not job then launch(1) end
        end

        openChapter(entry, function(viewer, err)
            if cancelled then return end
            if not viewer then
                if on_fail then on_fail(err) else finish(nil, err or _("打开漫画失败")) end
                return
            end
            finish(nil, nil, { handled = true })
        end)
    end

    --- 把选中的一册物化成独立册行：books 行（sync_status=0，reconcile 不动）+ 单条 toc。
    ---@param container BookIdentity series 容器身份
    ---@param entry BookChapter|table
    ---@return string|nil vol_stable
    local function ensureVolume(container, entry)
        local series_id = tostring(container.stable_id)
        local chapter_id = tostring(entry.chapterId or entry.uid)
        local vol_stable = volumeStableId(series_id, chapter_id)
        if not require("db.book").upsertLocal({
            source_id = self.id,
            stable_id = vol_stable,
            title = chapterLabel(entry),
            category = container.book and container.book.category,
            -- 册行继承容器的系列元数据：册自身没有简介/作者（服务端只在 series 级提供）。
            authors = container.book and container.book.authors,
            intro = container.book and container.book.intro,
            cover = series_id,
            deleted = 0,
            internal = 1, -- 册行是内部记录，不进书架列表
        }) then
            return nil
        end
        local stored = Toc.put(self.id, vol_stable, {{
            idx = 1,
            uid = tostring(entry.uid or chapter_id),
            source_idx = tostring(entry.source_idx or chapter_id),
            title = chapterLabel(entry),
            volume_name = entry.volume_name,
            file_name = entry.file_name,
            chapterId = entry.chapterId,
            volumeId = entry.volumeId,
            libraryId = entry.libraryId,
            seriesId = tonumber(series_id) or series_id,
            format = entry.format,
            pages = entry.pages,
            toc_version = TOC_VERSION,
        }})
        if not stored then return nil end
        -- 旧模型可能给容器下过整本：清掉容器缓存/路径，避免它伪装成已下载。
        if container.book and container.book.path then
            require("book.store").clearCache(self.id, series_id)
        end
        return vol_stable
    end

    --- 从容器目录取一册：漫画交 kamare，其余物化后下载。
    ---@param container BookIdentity
    ---@param entry BookChapter|table
    ---@param series_toc table[]
    local function openAsVolume(container, entry, series_toc)
        if isComicEntry(entry) and Kamare.available() then
            launchKamare(entry, series_toc, function(err)
                local vol_stable = ensureVolume(container, entry)
                if not vol_stable then
                    finish(nil, _("册信息保存失败"))
                    return
                end
                downloadNativeFallback(entry, vol_stable, { source_id = self.id, stable_id = vol_stable }, err)
            end)
            return
        end
        local vol_stable = ensureVolume(container, entry)
        if not vol_stable then
            finish(nil, _("册信息保存失败"))
            return
        end
        downloadEntry(entry, vol_stable, { source_id = self.id, stable_id = vol_stable })
    end

    local series_id = splitVolumeStable(identity.stable_id)
    if series_id then
        -- 已是册行：目录只有一条，直接打开/下载这一册（整书模式）。
        local entry = (Store.toc(identity) or {})[1]
        if not entry then
            finish(nil, _("章节目录缺失"))
            return { cancel = function() end }
        end
        if isComicEntry(entry) and Kamare.available() then
            launchKamare(entry, { entry }, function(err)
                downloadNativeFallback(entry, identity.stable_id, identity, err)
            end)
        else
            downloadEntry(entry, identity.stable_id, identity)
        end
        return { cancel = function()
            cancelled = true
            closeDialog()
        end }
    end

    local forced_idx = tonumber(opts.chapter_idx)
    if not forced_idx and opts.chapter_id ~= nil then
        forced_idx = Toc.index(identity.source_id, identity.stable_id, opts.chapter_id)
    end

    local cached_toc = Toc.read(identity.source_id, identity.stable_id)

    -- 单册 series 已下载整本：直接复用（离线也能开）；多册继续走选册。
    if not forced_idx then
        local path = identity.book and identity.book.path
        if type(path) == "string" and path ~= "" and fileExists(path) then
            local online = require("ui/network/manager"):isOnline()
            if (cached_toc and #cached_toc == 1) or (not cached_toc and not online) then
                cb(path)
                return { cancel = function() end }
            end
        end
    end

    self:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        if not toc or #toc == 0 then
            finish(nil, err or _("章节列表为空"))
            return
        end

        -- 章节模式显式指定册：直接物化，不再弹窗（连续阅读翻卷路径）。
        if forced_idx then
            openAsVolume(identity, toc[forced_idx] or toc[1], toc)
            return
        end
        -- 单册 series：整本打开，stable_id 仍是 seriesId。
        if #toc == 1 then
            if isComicEntry(toc[1]) and Kamare.available() then
                launchKamare(toc[1], toc, function(err)
                    downloadNativeFallback(toc[1], identity.stable_id, identity, err)
                end)
            else
                downloadEntry(toc[1], identity.stable_id, identity)
            end
            return
        end

        -- 多册 series：弹选册，标记已下载的册。
        local BookDB = require("db.book")
        local items = {}
        -- 不能用 `for _, entry`：`_` 是 gettext，会被循环变量遮蔽，下面 `_("已下载")` 会炸。
        for i = 1, #toc do
            local entry = toc[i]
            local vol_stable = volumeStableId(identity.stable_id, entry.chapterId or entry.uid)
            local row = BookDB.get(self.id, vol_stable)
            local downloaded = row and type(row.path) == "string" and row.path ~= ""
                and fileExists(row.path)
            local pages = tonumber(entry.pages) or 0
            local read = tonumber(entry.pagesRead) or 0
            local state
            if pages > 0 and read >= pages then state = _("已读")
            elseif read > 0 then state = _("在读") end
            items[#items + 1] = {
                text = chapterLabel(entry),
                value = entry.idx,
                mandatory = downloaded and _("已下载") or state,
            }
        end
        picker = require("ui.views.popup").single{
            title = _("选择要阅读的卷册"),
            subtitle = identity.book and identity.book.title or nil,
            items = items,
            current = downloadedChapterIdx(identity) or readingChapterIdx(toc),
            choice_icons = true,
            on_select = function(value)
                picker = nil
                if cancelled then return end
                local idx = tonumber(value)
                openAsVolume(identity, (idx and toc[idx]) or toc[1], toc)
            end,
        }
    end)

    return { cancel = function()
        cancelled = true
        closePicker()
        closeDialog()
    end }
end

--- 详情页按需刷新：拉本 series 的简介/作者写回，返回最新书行。
---@param identity BookIdentity
---@param cb fun(data: Book|nil, err: string|nil)
---@return { cancel: fun() }
function Source:getDetailAsync(identity, cb)
    local fallback = function()
        cb(identity.book or require("db.book").get(self.id, identity.stable_id))
    end
    if not self:configured() then
        fallback()
        return { cancel = function() end }
    end
    local cancelled = false
    local job = self._client:fetchSeriesMetadataAsync(seriesIdOf(identity.stable_id), function(data, err)
        if cancelled then return end
        if not data then
            cb(nil, err)
            return
        end
        require("book.store").rememberMany({{
            source_id = self.id,
            stable_id = identity.stable_id,
            intro = data.summary,
            authors = writersToAuthors(data.writers),
        }})
        fallback()
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
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
                        title = chapterDisplayTitle(chapter, volume) or "",
                        volume_name = cleanTitle(volume.name),
                        file_name = chapterFileName(chapter),
                        chapterId = chapter.id,
                        volumeId = volume.id or chapter.volumeId,
                        libraryId = series.libraryId,
                        seriesId = series.id,
                        format = formatName(chapter.format),
                        pages = chapter.pages,
                        pagesRead = chapter.pagesRead,
                    }
                end
            end
            if #list == 0 then cb(nil, _("章节列表为空")); return end
            list[1].toc_version = TOC_VERSION
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
    -- 旧目录缺 format（决定打开后缀/注解）或 toc_version（标题抽取规则）→ 过期重建。
    if cached and #cached > 0 and cached[1].format ~= nil
        and tonumber(cached[1].toc_version) == TOC_VERSION then
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
        -- Kavita 只给 spine 页级：pageNum 是 0-based spine，比例是「第几个 spine」，
        -- 不是内容比例。用 spine 造 xpointer 精确定位，bookScrollId 补页内锚点；
        -- 远端 percentage 不再反推成内容比例。
        local chapter_fraction = require("book.progress").clampFraction(
            pages > 0 and (page_num / pages) or 0)
        local idx = tonumber(identity.chapter_idx) or tonumber(entry.idx)
        local toc = require("source.toc").read(identity.source_id, identity.stable_id)
        local count = toc and #toc or 0
        local fraction = chapter_fraction
        if idx and count > 1 then
            fraction = ((idx - 1) + chapter_fraction) / count
        end
        local page = page_num + 1
        if pages > 0 and page > pages then page = pages end
        -- 网页端 bookScrollId 是 `id("X")`（元素 id），解析成 spine 内路径后才能与本地
        -- xpointer 比方向、跳转才精准；解析不到就退回「只到 spine」。
        local scroll_id = Anchor.resolveScrollId(bookFilePath(identity), page_num, data.bookScrollId)
        cb({
            fraction = require("book.progress").clampFraction(fraction),
            chapter_idx = idx,
            chapter_fraction = chapter_fraction,
            page = page,
            total_pages = pages,
            locator = Anchor.toXPointer(page_num, scroll_id, pages),
        }, nil, { page_level = true })
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
    local pages = entry and tonumber(entry.pages) or 0
    -- pageNum 的回退依据是「当前 spine 内的比例」：有 chapter_fraction 用它，
    -- 否则把全书比例折回当前册（心跳脏行只有全书比例）。
    local Progress = require("book.progress")
    local frac = pos.chapter_fraction
    if frac ~= nil then
        frac = Progress.clampFraction(frac)
    else
        local whole = Progress.clampFraction(pos.fraction)
        local toc = require("source.toc").read(identity.source_id, identity.stable_id)
        local idx = tonumber(identity.chapter_idx)
        local count = toc and #toc or 0
        if idx and count > 1 then
            frac = whole * count - (idx - 1)
            if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        else
            frac = whole
        end
    end
    -- pageNum 用真实 spine（`DocFragment`），不是内容比例×页数；心跳脏行也带
    -- locator，所以阅读期上报同样落到正确的 spine。缺 locator 才退回比例估算。
    local page_num = pageNumOf(pos, pages, frac)
    local series_id = (entry and entry.seriesId) or seriesIdOf(identity.stable_id)
    local payload = { pageNum = page_num }
    local scroll_id = Anchor.toScrollId(pos.locator)
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
    -- 只在明确已知非 EPUB 时跳过；format 取不到（旧目录/未同步）时按 EPUB 处理。
    local fmt = bookFormat(identity)
    if fmt ~= nil and fmt ~= "epub" then
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
    local series_id = (entry and entry.seriesId) or seriesIdOf(identity.stable_id)

    local pending = {}
    for _, ann in ipairs(annotations or {}) do
        if type(ann) == "table" and ann.drawer
            and type(ann.pos0) == "string" and ann.pos0 ~= "" then
            local mapped = mapping[ann.pos0]
            if not mapped then
                pending[#pending + 1] = { ann = ann, op = "create" }
            elseif mapped.annotationId and (mapped.comment or "") ~= (ann.note or "") then
                -- 已建注解的备注变更走 update；Kavita 的 update 只改 comment/slot/spoiler。
                pending[#pending + 1] = { ann = ann, op = "update", mapped = mapped }
            end
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
        local item = pending[index]
        if not item then cb(true); return end
        local ann = item.ann

        if item.op == "update" then
            local mapped = item.mapped
            current_job = self._client:updateAnnotationAsync({
                id = mapped.annotationId,
                chapterId = entry.chapterId,
                seriesId = series_id,
                volumeId = entry.volumeId,
                libraryId = entry.libraryId,
                ownerUserId = 0,
                xPath = mapped.xPath or "",
                endingXPath = mapped.endingXPath or "",
                selectedText = ann.text or "",
                comment = ann.note or "",
                commentHtml = "",
                selectedSlotIndex = 0,
                pageNumber = mapped.pageNumber or Anchor.pageNumber(ann.pos0) or 0,
                highlightCount = Text.utf16Length(ann.text),
                containsSpoiler = false,
            }, function(data, err)
                current_job = nil
                if cancelled then return end
                if data then
                    mapped.comment = ann.note or ""
                    saveJson(map_path, mapping)
                else
                    require("utils.log").warn("kavita annotation update failed", identity.stable_id, err)
                end
                nextAnn()
            end)
            return
        end

        local anchor = Anchor.compute(ann, epub_path)
        local page_number = anchor and anchor.pageNumber or Anchor.pageNumber(ann.pos0)
        local highlight_count = Text.utf16Length(ann.text)
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
                    comment = ann.note or "",
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
