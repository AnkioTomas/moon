--[[--
Kavita 书源（整本模式）。

身份：
  - 书架一行 = 一个 series，stable_id = seriesId，分类 = 库名。
  - 单卷 series 直接下载到 series 行；多卷 series 打开时选卷，每卷一行隐藏的书
    （stable_id = "seriesId:chapterId"，不上书架，只在最近阅读里出现），进度按卷同步。
目录缓存（source.toc，挂在 series 行）存每卷的 chapterId/volumeId/libraryId/format/pages，
是进度上报所需 id 的唯一来源；离线时目录过期也照用旧的。

进度：epub 按 spine（Kavita pageNum）+ bookScrollId，pdf/cbz 按页。
远端与本地落在同一 spine / 页时交回本地位置：Kavita 的精度只到 spine，
不能因此把本地章内位置判成冲突。
书架：快照指纹不变就跳过对账；对账后后台逐本补简介 / 作者；漫画 series 的已读页回填成本地进度。
划线：epub 的划线按段落文本在本地 epub 里找锚点，新建 / 改备注推到 Kavita，注解 id 存在笔记快照里。
漫画：装了 kamare 插件且在线时交它在线看（开书回调 handled），否则下载 cbz 用内置阅读器。

@module moonsource_kavita.source
--]]

local Client = require("moonsource_kavita.client")
local Position = require("moonsource_kavita.position")
local SourceBase = require("source.base")
local _ = require("gettext")
local T = require("ffi/util").template

local ID = "ext.kavita"
local PAGE_SIZE = 500
local FORMATS = { [0] = "image", [1] = "cbz", [3] = "epub", [4] = "pdf" }
local MAGIC = { epub = "PK\3\4", cbz = "PK\3\4", pdf = "%PDF" }

---@class KavitaSource : SourceBase
---@field client KavitaClient
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return BookSourceMeta
local function meta()
    return { id = ID, name = _("Kavita"), type = "book" }
end

---@return KavitaSource
local function new()
    local self = setmetatable(meta(), Source) --[[@as KavitaSource]]
    self.client = Client.new(require("utils.settings").getSource(ID))
    return self
end

function Source:configured()
    return self.client:configured()
end

---@return boolean
local function online()
    return require("ui/network/manager"):isConnected()
end

--- Kavita 标题：`-100000` 是「未命名」哨兵，纯数字卷名只是卷号。
---@param value any
---@return string|nil
local function title(value)
    if type(value) ~= "string" then return nil end
    value = require("utils.text").trim(value)
    if value == "" or value:match("^%-?%d+$") then return nil end
    return value
end

--- 文件头对得上格式才算下载完整（非 2xx 的错误页、截断的文件都过不了）。
---@param path string|nil
---@param format string|nil
---@return boolean
local function validFile(path, format)
    local file = path and io.open(path, "rb")
    if not file then return false end
    local head = file:read(4)
    file:close()
    return head == MAGIC[format]
end

---@param stable_id string
---@return string series_id, string|nil chapter_id
local function splitId(stable_id)
    local series_id, chapter_id = stable_id:match("^(%d+):(%d+)$")
    return series_id or stable_id, chapter_id
end

--- 身份对应的卷：有 chapterId 按它找，没有（series 行没下载过）且只有一卷时取唯一一卷。
---@param toc table[]
---@param chapter_id string|nil
---@return table|nil
local function findEntry(toc, chapter_id)
    if not chapter_id then return #toc == 1 and toc[1] or nil end
    for _idx, item in ipairs(toc) do
        if tostring(item.chapterId) == chapter_id then return item end
    end
    return nil
end

--- 已登记且完整的本地文件。
---@param source_id string
---@param stable_id string
---@return string|nil
local function downloaded(source_id, stable_id)
    local book = require("book.books_db").get(source_id, stable_id)
    local path = book and book.path
    if path and validFile(path, path:match("%.(%w+)$")) then return path end
    return nil
end

---@param metadata table Kavita SeriesMetadataDto
---@return string|nil
local function authorsOf(metadata)
    local authors = {}
    for _idx, writer in ipairs(metadata.writers or {}) do authors[#authors + 1] = writer.name end
    return #authors > 0 and table.concat(authors, " / ") or nil
end

--- SeriesMetadataDto 写回书库的字段（作者 / 简介 / 出版社 / 年份 / 语言）。
--- Kavita 的未知值是空串 / 0 / 空表，入库时由 BookDB 规范化丢掉。
---@param row table 至少带 source_id / stable_id
---@param metadata table
---@return table row
local function withMetadata(row, metadata)
    local publishers = {}
    for _idx, person in ipairs(metadata.publishers or {}) do publishers[#publishers + 1] = person.name end
    row.authors, row.intro = authorsOf(metadata), metadata.summary
    row.meta = {
        publisher = table.concat(publishers, " / "),
        published = metadata.releaseYear,
        language = metadata.language,
    }
    return row
end

--- Kavita 的时间是不带时区的 UTC（`2026-09-29T20:07:19.193`）。
---@param value any
---@return integer|nil
local function utcTime(value)
    local y, mo, d, h, mi, s = tostring(value or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y or tonumber(y) < 1971 then return nil end
    local now = os.time()
    local offset = now - os.time(os.date("!*t", now) --[[@as osdate]])
    return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) }) + offset
end

--- 漫画 series 的已读页数回填成本地进度（远端版，本地脏行不覆盖），书架上直接看得到进度。
--- epub/pdf 不回填：series 级页数是 spine 数，粒度太粗，会盖掉本地的精确位置。
---@param source_id string
---@param comics table[] Kavita SeriesDto
---@return integer changed
local function backfillComics(source_id, comics)
    local ProgressDB = require("book.progress_db")
    local changed = 0
    for _idx, series in ipairs(comics) do
        local pages, read = tonumber(series.pages) or 0, tonumber(series.pagesRead) or 0
        local stable_id = tostring(series.id)
        local here = ProgressDB.get(source_id, stable_id)
        if pages > 0 and read > 0 and not (here and here.page == read)
            and ProgressDB.upsertRemote(source_id, stable_id, {
                fraction = math.min(1, read / pages),
                page = read,
                total_pages = pages,
                updated_at = utcTime(series.latestReadDate),
            }) then
            changed = changed + 1
        end
    end
    return changed
end

--- 后台逐本补简介 / 作者（all-v2 不带，metadata 一本一请求）。已有简介的跳过；
--- 补过的 series 记在 settings/moonsource_kavita_meta.lua（书库把空简介存成 NULL，
--- 没简介的书靠它才不会每次同步都重拉）。任一请求失败就停，下次书架同步再接着补。
---@param series_ids string[]
function Source:backfillMeta(series_ids)
    if self.backfill then self.backfill.cancel() end
    local BookDB = require("book.books_db")
    local UIManager = require("ui/uimanager")
    local state = require("luasettings"):open(require("datastorage"):getSettingsDir() .. "/moonsource_kavita_meta.lua")
    local done = state:readSetting("done", {})
    local index, cancelled, job, timer = 0, false, nil, nil
    local function stop()
        self.backfill = nil
        state:flush()
    end
    local function step()
        local series_id, book
        repeat
            index = index + 1
            series_id = series_ids[index]
            book = series_id and not done[series_id] and BookDB.get(self.id, series_id)
        until not series_id or (book and book.intro == nil)
        if not series_id or not online() then return stop() end
        job = self.client:json("GET", "/api/Series/metadata", { seriesId = series_id }, nil, function(metadata)
            if cancelled then return end
            if not metadata then return stop() end
            require("book.store").rememberMany({
                withMetadata({ source_id = self.id, stable_id = series_id }, metadata),
            })
            done[series_id] = true
            timer = step
            UIManager:scheduleIn(0.3, timer)
        end)
    end
    self.backfill = { cancel = function()
        cancelled = true
        if job then job:cancel() end
        if timer then UIManager:unschedule(timer) end
        stop()
    end }
    step()
end

--- 详情页缺简介时补：series 的 metadata 写回这一行（卷行用所属 series 的）。
---@param identity BookIdentity
---@param cb fun(book: Book|nil, err: string|nil)
---@return { cancel: fun() }
function Source:getDetailAsync(identity, cb)
    return self.client:json("GET", "/api/Series/metadata", { seriesId = splitId(identity.stable_id) }, nil,
        function(metadata, err)
            if not metadata then return cb(nil, err) end
            local book = withMetadata({ source_id = self.id, stable_id = identity.stable_id }, metadata)
            require("book.store").rememberMany({ book })
            cb(book)
        end)
end

function Source:close()
    if self.backfill then self.backfill.cancel() end
end

--- 书架：所选库的全部 series 交给书库对账。Kavita 没有删书接口，dirty_only 跳过，
--- 本地删除留墓碑，对账不会复活。
--- 远端快照（库 + 每本 id/名称/库名/字数）的指纹没变、本地书架也非空时跳过对账：
--- 本地书架只会被对账和删除改动，删除留墓碑本来就不用对账；force 刷新照常对账。
---@param opts { dirty_only?: boolean, force?: boolean, on_progress?: fun(text: string|nil, done: integer|nil, total: integer|nil) }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }
function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    if opts.dirty_only then return SourceBase.skipped(cb, "no remote delete") end
    local libraries = {}
    for id in pairs(require("utils.settings").getSource(ID).libraries or {}) do
        libraries[#libraries + 1] = id
    end
    if not self:configured() or #libraries == 0 then
        return SourceBase.defer(cb, nil, _("请先在设置里填写 Kavita 服务器并选择书库"))
    end
    table.sort(libraries)
    local report = opts.on_progress or function() end
    local books, comics, prints, lib_index, page, cancelled = {}, {}, { table.concat(libraries, ",") }, 1, 1, false
    ---@type HttpJob
    local job

    local function finish()
        local settings = require("utils.settings")
        local cfg = settings.getSource(ID)
        local fingerprint = require("ffi/sha2").md5(table.concat(prints, "\n"))
        local result, err
        if not opts.force and cfg.shelf_fingerprint == fingerprint
            and #require("book.books_db").libraryStableIdsBySource(self.id) > 0 then
            result = { pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
        else
            result, err = require("source.shelf").reconcile(self.id, books, opts.force)
            if not result then return cb(nil, err) end
            cfg.shelf_fingerprint = fingerprint
            settings.saveSource(ID, cfg)
            local ids = {}
            for idx, book in ipairs(books) do ids[idx] = book.stable_id end
            self:backfillMeta(ids)
        end
        -- 跳过对账时只有漫画进度可能变了，计进 pulled 让书架重绘。
        result.pulled = result.pulled + backfillComics(self.id, comics)
        cb(result)
    end

    local function fetch()
        report(T(_("正在拉取书架（%1 本）"), #books))
        local query = { pageNumber = page, pageSize = PAGE_SIZE }
        -- Field 19 = 库，Comparison 0 = 等于，SortField 1 = 按名称。
        local body = {
            Statements = { { Field = 19, Comparison = 0, Value = libraries[lib_index] } },
            Combination = 1,
            SortOptions = { SortField = 1, IsAscending = true },
        }
        job = self.client:json("POST", "/api/Series/all-v2", query, body, function(list, err)
            if cancelled then return end
            if not list then return cb(nil, err) end
            for _idx, series in ipairs(list) do
                books[#books + 1] = {
                    stable_id = tostring(series.id),
                    title = series.name,
                    category = series.libraryName,
                    meta = { words = series.wordCount },
                }
                prints[#prints + 1] = table.concat({ series.id, series.name or "", series.libraryName or "",
                    tonumber(series.wordCount) or 0 }, "\31")
                if tonumber(series.format) == 1 then comics[#comics + 1] = series end
            end
            if #list >= PAGE_SIZE then
                page = page + 1
            elseif lib_index < #libraries then
                lib_index, page = lib_index + 1, 1
            else
                return finish()
            end
            fetch()
        end)
    end
    fetch()
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

--- series 的卷目录：series（取 libraryId）→ volumes → metadata（作者 / 简介写回书库，失败不影响目录）。
---@param series_id string
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }
function Source:fetchToc(series_id, cb)
    local cancelled = false
    ---@type HttpJob
    local job
    local function step(method, path, query, done)
        job = self.client:json(method, path, query, nil, function(data, err)
            if not cancelled then done(data, err) end
        end)
    end
    step("GET", "/api/Series/" .. series_id, nil, function(series, err)
        if not series then return cb(nil, err) end
        step("GET", "/api/Series/volumes", { seriesId = series_id }, function(volumes, verr)
            if not volumes then return cb(nil, verr) end
            local toc = {}
            for _vidx, volume in ipairs(volumes) do
                for _cidx, chapter in ipairs(volume.chapters or {}) do
                    local file = chapter.files and chapter.files[1] and chapter.files[1].filePath
                    toc[#toc + 1] = {
                        idx = #toc + 1,
                        uid = tostring(chapter.id),
                        title = title(chapter.titleName) or title(chapter.title) or title(volume.name)
                            or (file and file:match("([^/\\]+)%.[^.]+$")) or series.name,
                        chapterId = chapter.id,
                        volumeId = volume.id,
                        libraryId = series.libraryId,
                        seriesId = series.id,
                        format = FORMATS[tonumber(chapter.format) or tonumber(series.format)],
                        pages = tonumber(chapter.pages) or 0,
                        pagesRead = tonumber(chapter.pagesRead) or 0,
                    }
                end
            end
            if #toc == 0 then return cb(nil, _("这本书在 Kavita 上没有可读的卷")) end
            if not require("source.toc").put(self.id, series_id, toc) then
                return cb(nil, _("章节目录保存失败"))
            end
            step("GET", "/api/Series/metadata", { seriesId = series_id }, function(metadata)
                if metadata then
                    require("book.store").rememberMany({
                        withMetadata({ source_id = self.id, stable_id = series_id, title = series.name }, metadata),
                    })
                end
                cb(toc)
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

--- 目录：新鲜缓存 > 在线拉取 > 离线时的过期缓存（已下载的卷离线也要能开、能记进度）。
---@param series_id string
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }
function Source:toc(series_id, cb)
    local cached = require("source.toc").read(self.id, series_id)
    if cached then return SourceBase.defer(cb, cached) end
    if online() then return self:fetchToc(series_id, cb) end
    local payload = require("book.books_db").getToc(self.id, series_id)
    local ok, stale = pcall(require("json").decode, payload or "")
    if ok and type(stale) == "table" then return SourceBase.defer(cb, stale) end
    return SourceBase.defer(cb, nil, _("网络不可用，请先连接 Wi-Fi"))
end

--- 身份对应的卷。series 行的卷号取自登记的文件名（<chapterId>.<ext>）。
---@param identity BookIdentity
---@param cb fun(entry: table|nil, err: string|nil)
---@return { cancel: fun() }
function Source:entry(identity, cb)
    local series_id, chapter_id = splitId(identity.stable_id)
    if not chapter_id then
        local path = downloaded(self.id, identity.stable_id)
        chapter_id = path and path:match("(%d+)%.%w+$")
    end
    return self:toc(series_id, function(toc, err)
        if not toc then return cb(nil, err) end
        local entry = findEntry(toc, chapter_id)
        cb(entry, not entry and _("这一卷已不在 Kavita 上") or nil)
    end)
end

--- 下载一卷到 ref 的工作目录并登记路径；已下载的直接登记。
---@param ref BookIdentity
---@param entry table
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:fetchVolume(ref, entry, cb)
    local Paths = require("utils.paths")
    if not MAGIC[entry.format] then
        return SourceBase.defer(cb, nil, _("图片目录格式需要安装 kamare 插件在线阅读"))
    end
    Paths.ensureBookWork(ref.stable_id, self.id)
    local path = T("%1/%2.%3", Paths.bookWorkDir(ref.stable_id, self.id), entry.chapterId, entry.format)
    local function register()
        local ok, err = require("book.store").touch(path, ref)
        cb(ok and path or nil, err)
    end
    if validFile(path, entry.format) then return SourceBase.defer(register) end
    if not online() then return SourceBase.defer(cb, nil, _("网络不可用，请先连接 Wi-Fi")) end
    local dialog = require("ui.themes.widgets.progress_dialog"):new{ title = entry.title, dismissable = false }
    dialog:show()
    dialog:set(_("正在下载…"))
    local job = self.client:download(entry.chapterId, path, function(bytes, total)
        if total and total > 0 then dialog:bytes(bytes, total) end
    end, function(ok, err)
        dialog:close()
        if not ok then return cb(nil, err or _("下载失败")) end
        if not validFile(path, entry.format) then
            os.remove(path)
            return cb(nil, _("下载文件校验失败"))
        end
        register()
    end)
    return { cancel = function()
        job:cancel()
        dialog:close()
    end }
end

--- 打开一卷：漫画（cbz / 图片目录）在线且装了 kamare 就从 Kavita 记录的页交它在线看，
--- 回调 handled；kamare 打不开时 cbz 退回下载，图片目录报错。其余格式下载。
--- 关查看器时把页码记成远端版本地进度（kamare 已推给 Kavita），书架看得到进度。
---@param ref BookIdentity 承载这一卷的书库行
---@param entry table
---@param toc table[] 同 series 的卷，章末续读按 chapterId 找下一卷
---@param title string
---@param cb fun(path: string|nil, err: string|nil, meta: { handled: boolean }|nil)
---@return { cancel: fun() }
function Source:openEntry(ref, entry, toc, title, cb)
    local Kamare = require("moonsource_kavita.kamare")
    local cached = MAGIC[entry.format] and validFile(
        T("%1/%2.%3", require("utils.paths").bookWorkDir(ref.stable_id, self.id), entry.chapterId, entry.format),
        entry.format)
    if (entry.format ~= "cbz" and entry.format ~= "image") or cached or not online() or not Kamare.available() then
        return self:fetchVolume(ref, entry, cb)
    end
    local job, cancelled = nil, false
    local function show(item, start_page)
        return Kamare.open({
            base_url = self.client.base_url, api_key = self.client.api_key,
            entry = item, title = title, start_page = start_page,
            on_close = function(page, total)
                total = tonumber(total) or item.pages
                page = tonumber(page) or 1
                if total > 0 then
                    require("book.progress_db").upsertRemote(self.id, ref.stable_id, {
                        fraction = math.min(1, page / total), page = page, total_pages = total,
                        updated_at = os.time(),
                    })
                end
            end,
            on_next = function(next_id)
                for _idx, next_entry in ipairs(toc) do
                    if tostring(next_entry.chapterId) == tostring(next_id) then return show(next_entry, 1) end
                end
            end,
        })
    end
    job = self.client:json("GET", "/api/Reader/get-progress", { chapterId = entry.chapterId }, nil, function(remote)
        if cancelled then return end
        local read = remote and tonumber(remote.pageNum) or 0
        local viewer, err = show(entry, math.max(1, math.min(read + 1, entry.pages)))
        if viewer then return cb(nil, nil, { handled = true }) end
        if entry.format ~= "cbz" then return cb(nil, err) end
        job = self:fetchVolume(ref, entry, cb)
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

--- 多卷选卷：标注已下载 / 在读 / 已读；关窗没选算取消。
---@param series Book
---@param toc table[]
---@param cb fun(entry: table|nil)
local function pickVolume(series, toc, cb)
    local Paths = require("utils.paths")
    local items = {}
    for _idx, entry in ipairs(toc) do
        local vid = series.stable_id .. ":" .. entry.chapterId
        local state
        if entry.pages > 0 and entry.pagesRead >= entry.pages then
            state = _("已读")
        elseif entry.pagesRead > 0 then
            state = _("在读")
        end
        if entry.format and validFile(T("%1/%2.%3", Paths.bookWorkDir(vid, ID), entry.chapterId, entry.format), entry.format) then
            state = state and T(_("%1 · 已下载"), state) or _("已下载")
        end
        items[#items + 1] = { text = entry.title, value = entry, mandatory = state }
    end
    local chosen = false
    require("ui.themes.widgets.list"):new{
        title = series.title or _("选择卷"),
        items = items,
        on_select = function(entry)
            chosen = true
            cb(entry)
        end,
        -- 单选点按时先关窗、同一拍再 on_select：下一拍还没选中就是用户关掉了列表。
        close_callback = function()
            require("ui/uimanager"):nextTick(function()
                if not chosen then cb(nil) end
            end)
        end,
    }:show()
end

--- 打开：已下载的直接开（不联网）；单卷 series 下到 series 行，多卷选卷后下到卷行。
function Source:openBookAsync(identity, _opts, cb)
    local path = downloaded(self.id, identity.stable_id)
    if path then return SourceBase.defer(cb, path) end
    local job, cancelled = nil, false
    local function finish(file, err, meta)
        if not cancelled then cb(file, err, meta) end
    end
    local series_id, chapter_id = splitId(identity.stable_id)
    job = self:toc(series_id, function(toc, err)
        if not toc then return finish(nil, err) end
        if chapter_id or #toc == 1 then
            local entry = findEntry(toc, chapter_id)
            if not entry then return finish(nil, _("这一卷已不在 Kavita 上")) end
            local name = identity.book and identity.book.title or entry.title
            job = self:openEntry(identity, entry, toc, name, finish)
            return
        end
        local series = identity.book or { stable_id = series_id }
        pickVolume(series, toc, function(entry)
            if cancelled then return end
            if not entry then return finish(nil, _("已取消")) end
            local ref = { source_id = self.id, stable_id = series_id .. ":" .. entry.chapterId }
            require("book.store").rememberMany({ {
                source_id = self.id, stable_id = ref.stable_id,
                title = T("%1 · %2", series.title or "", entry.title),
                authors = series.authors, series = series.title,
            } })
            job = self:openEntry(ref, entry, toc, series.title or entry.title, finish)
        end)
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

---@param identity BookIdentity
---@return BookCoverRequest|nil, string|nil
function Source:coverRequest(identity)
    if not self:configured() then return nil, _("未配置") end
    local series_id, chapter_id = splitId(identity.stable_id)
    local url = chapter_id and self.client:url("/api/Image/chapter-cover", { chapterId = chapter_id })
        or self.client:url("/api/Image/series-cover", { seriesId = series_id })
    return { url = url, headers = self.client:headers() }
end

--- Kavita 进度 → 月读位置；与本地同一 spine / 页时交回本地行。
---@param identity BookIdentity
---@param entry table
---@param remote { pageNum: integer, bookScrollId: string|nil }
---@return ProgressPosition
function Source:position(identity, entry, remote)
    local pages = math.max(entry.pages, 1)
    local page_num = math.min(tonumber(remote.pageNum) or 0, pages)
    local fraction = page_num / pages
    local here = require("book.progress_db").get(self.id, identity.stable_id)
    if entry.format == "epub" then
        local spine = math.min(page_num, pages - 1)
        if here and Position.spine(here.locator) == spine then return here end
        local book = require("book.books_db").get(self.id, identity.stable_id)
        local scroll = Position.resolveScrollId(book and book.path, spine, remote.bookScrollId)
        return { fraction = fraction, locator = Position.toXPointer(spine, scroll, pages) }
    end
    local page = math.max(1, math.min(page_num + 1, pages))
    if here and here.page == page then return here end
    return { fraction = fraction, page = page, total_pages = pages }
end

function Source:getProgressAsync(identity, cb)
    local job, cancelled = nil, false
    job = self:entry(identity, function(entry, err)
        if cancelled then return end
        if not entry then return cb(nil, err) end
        job = self.client:json("GET", "/api/Reader/get-progress", { chapterId = entry.chapterId }, nil,
            function(remote, perr, code)
                if cancelled then return end
                -- 没读过：旧版本回 400/404，新版本回 pageNum=0 且无锚点。
                if code == 400 or code == 404 or (remote and (tonumber(remote.pageNum) or 0) == 0
                    and not remote.bookScrollId) then
                    return cb(nil, nil, { empty = true })
                end
                if not remote then return cb(nil, perr) end
                cb(self:position(identity, entry, remote))
            end)
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

--- 月读位置 → Kavita pageNum（0-based spine / 页），读完发 pages。
function Source:putProgressAsync(identity, pos, cb)
    local job, cancelled = nil, false
    job = self:entry(identity, function(entry, err)
        if cancelled then return end
        if not entry then return cb(nil, err) end
        local pages = math.max(entry.pages, 1)
        local fraction = tonumber(pos.fraction) or 0
        local page_num
        if entry.format == "epub" then
            page_num = Position.spine(pos.locator)
        elseif pos.page then
            page_num = pos.page - 1
        end
        page_num = math.max(0, math.min(page_num or math.floor(fraction * pages), pages - 1))
        if fraction >= 1 then page_num = pages end
        job = self.client:json("POST", "/api/Reader/progress", nil, {
            pageNum = page_num,
            bookScrollId = entry.format == "epub" and Position.toScrollId(pos.locator) or nil,
            chapterId = entry.chapterId,
            volumeId = entry.volumeId,
            libraryId = entry.libraryId,
            seriesId = entry.seriesId,
        }, function(data, perr)
            if not cancelled then cb(data and true, perr) end
        end)
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

--- 注解快照保留 Kavita 注解 id 与已推送的备注：核心按 pos0 之外的字段一律丢弃。
---@param items table[]
---@param total_pages integer|nil
---@return table[]
function Source:cleanAnnotations(items, total_pages)
    local Normalize = require("book.note.normalize")
    local out = {}
    for _idx, item in ipairs(items) do
        local clean = Normalize.clean({ item }, total_pages)[1]
        if clean then
            clean.kavita_id, clean.kavita_note = item.kavita_id, item.kavita_note
            out[#out + 1] = clean
        end
    end
    return out
end

--- 阅读器里的注解不带 Kavita id：按 pos0 从上一版快照接过来，免得每次保存都重建远端注解。
---@param previous table[]
---@param current table[]
---@return table[]
function Source:prepareLocalAnnotations(previous, current)
    local by_pos = {}
    for _idx, old in ipairs(previous) do
        if old.kavita_id and old.pos0 then by_pos[old.pos0] = old end
    end
    for _idx, item in ipairs(current) do
        local old = item.pos0 and by_pos[item.pos0]
        if old and not item.kavita_id then
            item.kavita_id, item.kavita_note = old.kavita_id, old.kavita_note
        end
    end
    return current
end

--- Kavita 的 highlightCount 按 UTF-16 码元计。
---@param s string
---@return integer
local function utf16Length(s)
    local n = 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + (#ch == 4 and 2 or 1) end
    return n
end

--- 划线推到 Kavita：没 id 的新建、备注改过的更新，id 原地回填由核心落库。
--- Kavita 只认 epub 注解；删除不同步（远端删除接口未确认，宁可多留不误删）。
--- 有一条成功就算成功（回填的 id 要落库，否则重试会重复建），失败的那几条没 id，下次笔记变动再推；
--- 全部失败才报错，脏标记留着重试。
---@param identity BookIdentity
---@param annotations table[]
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Source:pushNotesAsync(identity, annotations, cb)
    local job, cancelled = nil, false
    job = self:entry(identity, function(entry, err)
        if cancelled then return end
        if not entry then return cb(nil, err) end
        if entry.format ~= "epub" then return cb(true) end
        local path = downloaded(self.id, identity.stable_id)
        local pending = {}
        for _idx, ann in ipairs(annotations) do
            if ann.drawer and type(ann.pos0) == "string" and type(ann.text) == "string"
                and (not ann.kavita_id or (ann.kavita_note or "") ~= (ann.note or "")) then
                pending[#pending + 1] = ann
            end
        end
        local index, pushed, failed = 0, 0, nil
        local function nextOne()
            index = index + 1
            local ann = pending[index]
            if not ann then
                if pushed == 0 and failed then return cb(nil, failed) end
                return cb(true)
            end
            local anchor = Position.anchor(ann.text, ann.pos0, path) or {}
            local body = {
                id = ann.kavita_id,
                chapterId = entry.chapterId, volumeId = entry.volumeId,
                libraryId = entry.libraryId, seriesId = entry.seriesId,
                ownerUserId = 0,
                xPath = anchor.xPath or "", endingXPath = anchor.endingXPath or "",
                selectedText = ann.text, comment = ann.note or "", commentHtml = "",
                selectedSlotIndex = 0, containsSpoiler = false,
                pageNumber = anchor.pageNumber or Position.spine(ann.pos0) or 0,
                highlightCount = utf16Length(ann.text),
            }
            local api = ann.kavita_id and "/api/Annotation/update" or "/api/Annotation/create"
            job = self.client:json("POST", api, nil, body, function(data, perr)
                if cancelled then return end
                if data then
                    ann.kavita_id = ann.kavita_id or data.id
                    ann.kavita_note = ann.note or ""
                    pushed = pushed + 1
                else
                    failed = failed or perr
                end
                nextOne()
            end)
        end
        nextOne()
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

return { meta = meta, new = new }
