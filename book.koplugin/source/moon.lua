--[[--
Book (moon) 数据源门面
  client：HTTP wire（仅异步）
  mapper：wire → 领域对象

@module koplugin.book.source.moon
--]]

local Client = require("source.moon.client")
local Mapper = require("source.moon.mapper")
local SourceBase = require("source.base")
local ProgressPosition = require("types.book_progress")
local _ = require("gettext")

local Moon = {}

local BOOK_EXTENSIONS = {
    epub = true,
    pdf = true,
    cbz = true,
    cbr = true,
    mobi = true,
    azw3 = true,
    txt = true,
}

---@type table<string, function[]>
local opening = {}

---@param identity BookIdentity
---@return string
local function bookPath(identity)
    local Paths = require("utils.paths")
    local ext = identity.stable_id:match("%.([%w]+)$")
    ext = ext and string.lower(ext) or nil
    Paths.ensureBookWork(identity.stable_id, identity.source_id)
    return Paths.bookWorkDir(identity.stable_id, identity.source_id)
        .. "/book." .. (BOOK_EXTENSIONS[ext] and ext or "epub")
end

---@param path string
---@param format_path string|nil
---@return boolean
local function validBook(path, format_path)
    local attr = require("libs/libkoreader-lfs").attributes(path)
    if not attr or attr.mode ~= "file" or not attr.size or attr.size < 4 then
        return false
    end
    local file = io.open(path, "rb")
    if not file then return false end
    local head = file:read(4) or ""
    file:close()

    local ext = (format_path or path):match("%.([^.]+)$")
    ext = ext and string.lower(ext) or nil
    if ext == "txt" then return true end
    if ext == "mobi" or ext == "azw3" then
        if attr.size < 68 then return false end
        file = io.open(path, "rb")
        if not file then return false end
        file:seek("set", 60)
        local palm = file:read(8) or ""
        file:close()
        return palm == "BOOKMOBI" or palm == "TEXtREAd"
    end
    if ext == "epub" or ext == "cbz" then
        return head == "PK\003\004" or head == "PK\005\006"
    end
    if ext == "cbr" then
        return head == "Rar!" or head == "PK\003\004"
    end
    return ext == "pdf" and head == "%PDF"
end

---@param key string
---@param start fun(done: fun(ok: boolean, path: string|nil, err: any))
---@param cb fun(ok: boolean, path: string|nil, err: any)
local function shareOpening(key, start, cb)
    local waiters = opening[key]
    if waiters then
        waiters[#waiters + 1] = cb
        return
    end
    opening[key] = { cb }
    start(function(ok, path, err)
        waiters = opening[key]
        opening[key] = nil
        for i = 1, #waiters do
            waiters[i](ok, path, err)
        end
    end)
end

--- 返回 Moon 源元信息。
---@return BookSourceMeta
function Moon.meta()
    return {
        id = "moon",
        name = _("月读服务"),
        type = "book",
    }
end

---@class MoonSource : SourceBase
---@field _client MoonClient
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

--- 构造 Moon 源实例。
---@return MoonSource
function Moon.new()
    local cfg = require("utils.settings").getSource("moon")
    local meta = Moon.meta()
    ---@type MoonSource
    local self = setmetatable({
        id = meta.id,
        name = meta.name,
        type = meta.type,
        _client = Client:new(cfg),
    }, Source)
    return self
end

--- 返回 Moon 源能力集。
---@return SourceCapabilities
function Source:capabilities()
    return {
        search = true,
        refresh = true,
        scrape = false,
        edit = false,
        insight = true,
        stats_pull = true,
        store = false,
    }
end

--- 是否已配置 Moon 源。
---@return boolean
function Source:configured()
    return self._client:configured()
end

--- 删除 Moon 书籍的本地文件、封面和登记；不删除云端原书。
---@param identity BookIdentity
---@param cb fun(ok: boolean, err: string|nil)
---@return table
function Source:deleteBookAsync(identity, cb)
    local cancelled = false
    require("ui/uimanager"):nextTick(function()
        if cancelled then return end
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
        cb(true)
    end)
    return { cancel = function() cancelled = true end }
end

--- 打开 Moon 整本书：缓存命中直开，否则下载、校验并登记物理路径。
---@param identity BookIdentity
---@param _opts table|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:openBookAsync(identity, _opts, cb)
    local cancelled = false
    local dialog
    local path = bookPath(identity)

    --- 关掉下载进度对话框并置空句柄；重复调用无副作用。
    local function closeDialog()
        if dialog then
            dialog:close()
            dialog = nil
        end
    end

    --- 把已就绪的物理文件登记进书库，再把路径交给调用方。
    ---@param local_path string 本地书籍文件路径
    local function register(local_path)
        local ok, err = require("book.store").touch(local_path, identity)
        if ok then
            cb(local_path)
        else
            cb(nil, err)
        end
    end

    local book = identity.book
    if not book or not book.path then
        book = require("db.book").get(identity.source_id, identity.stable_id) or book
    end
    local registered_path = book and book.path
    if registered_path and validBook(registered_path, identity.stable_id) then
        register(registered_path)
        return { cancel = function() cancelled = true end }
    end
    if validBook(path) then
        register(path)
        return { cancel = function() cancelled = true end }
    end
    os.remove(path)

    require("ui/network/manager"):runWhenOnline(function()
        if cancelled then return end
        shareOpening(identity.stable_id, function(done)
            local book = identity.book or {}
            local title = book.title
                or (identity.stable_id:match("([^/\\]+)$") or identity.stable_id)
            local size = tonumber(book.fileSize or book.filesize or book.size or book.file_size)
            local has_dialog, ProgressbarDialog = pcall(require, "ui/widget/progressbardialog")
            if has_dialog and ProgressbarDialog then
                dialog = ProgressbarDialog:new{
                    title = _("正在下载…"),
                    subtitle = title,
                    progress_max = (size and size > 0) and size or nil,
                    refresh_time_seconds = 1,
                    dismissable = false,
                }
                dialog:show()
            else
                require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
                    text = _("正在下载…"),
                })
            end

            local temp_path = path .. ".part"
            self._client:downloadBookAsync(identity.stable_id, temp_path, dialog and function(bytes)
                if dialog then dialog:reportProgress(bytes) end
            end or nil, function(ok, err)
                closeDialog()
                if not ok then
                    os.remove(temp_path)
                    done(false, nil, (type(err) == "table" and err.message) or err)
                    return
                end
                if not validBook(temp_path, path) then
                    os.remove(temp_path)
                    done(false, nil, _("下载文件校验失败"))
                    return
                end
                os.remove(path)
                if not os.rename(temp_path, path) then
                    os.remove(temp_path)
                    done(false, nil, _("无法保存文件"))
                    return
                end
                done(true, path)
            end)
        end, function(ok, local_path, err)
            if cancelled then return end
            if not ok then
                cb(nil, err or _("下载失败"))
                return
            end
            register(local_path)
        end)
    end)

    return {
        cancel = function()
            cancelled = true
            closeDialog()
        end,
    }
end

--- 把 BookListOpts 转成 Moon list API 的 query 表。
---@param opts BookListOpts|nil
---@return table
local function listQuery(opts)
    opts = opts or {}
    return {
        page = opts.page or 1,
        pageSize = opts.page_size or 50,
        search = opts.search or "",
        series = opts.series or "",
        category = opts.category or "",
    }
end

--- 拉取服务端最近阅读，保存元数据和远端进度后直接按服务端顺序返回。
---@param limit number|nil
---@param cb fun(data: BookListResult|nil, err: string|nil)
---@return table|nil
function Source:recentBooksAsync(limit, cb)
    limit = math.max(1, math.min(50, tonumber(limit) or 24))
    return self._client:recentBooksAsync(limit, function(wire, err)
        if not wire then
            SourceBase.recentBooksAsync(self, limit, cb)
            return
        end
        local mapped = Mapper.list(wire)
        for _, book in ipairs(mapped.data) do
            book.in_library = true
        end
        require("book.store").rememberMany(mapped.data)
        local raw = type(wire.data) == "table" and wire.data or {}
        local ProgressDB = require("db.progress")
        for _, row in ipairs(raw) do
            local book = Mapper.book(row)
            local pos = Mapper.progress({ data = row })
            if book and pos then
                ProgressDB.upsertRemote(self.id, book.stable_id, pos)
            end
        end
        cb(mapped)
    end)
end

--- 清空 Moon 书库/统计相关 HTTP 缓存。
function Source:clearCaches()
    local ok, Request = pcall(require, "http.request")
    if ok and Request and Request.clearCache then
        Request.clearCache("/index/book/")
        Request.clearCache("/index/stats/")
    end
end

--- 构造 Moon 封面请求。
---@param identity BookIdentity
---@return BookCoverRequest|nil, string|nil
function Source:coverRequest(identity)
    local req, err = self._client:coverRequest(identity.stable_id)
    if not req then
        return nil, (type(err) == "table" and err.message) or err
    end
    return req
end

--- 分页拉取完整 Moon 书架，全部成功后一次性对账本地库。
---@param opts { force?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }
function Source:syncBooksAsync(opts, cb)
    if opts and opts.force then self:clearCaches() end
    local page, page_size = 1, 200
    local books, cancelled, job = {}, false, nil
    --- 拉下一页书架；累计条数够 count 或本页为空即收尾并对账入库。
    local function nextPage()
        if cancelled then return end
        job = self._client:listBooksAsync(listQuery({ page = page, page_size = page_size }), function(wire, err)
            job = nil
            if cancelled then return end
            if not wire then cb(nil, (type(err) == "table" and err.message) or err); return end
            local mapped = Mapper.list(wire)
            for _, book in ipairs(mapped.data or {}) do books[#books + 1] = book end
            local count = tonumber(mapped.count) or #books
            if #books < count and #(mapped.data or {}) > 0 then
                page = page + 1
                nextPage()
                return
            end
            cb(require("book.store").reconcile(self.id, books))
        end)
    end
    nextPage()
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job:cancel() end
    end }
end

--- 把领域统计记录转换成 Moon 的上报协议。
--- 设备标识和 books/stats wire 字段属于 Source，不泄漏到 book.stats。
---@param rows table[]
---@param cb fun(data: table|nil, err: string|nil)
---@return table|nil
function Source:pushStatsAsync(rows, cb)
    rows = rows or {}
    local books, stats, seen = {}, {}, {}
    for _, row in ipairs(rows) do
        if type(row.stable_id) == "string" and row.stable_id ~= "" then
            if not seen[row.stable_id] then
                seen[row.stable_id] = true
                books[#books + 1] = { filename = row.stable_id }
            end
            stats[#stats + 1] = {
                filename = row.stable_id,
                page = row.page,
                start_time = row.start_time,
                duration = row.duration,
                total_pages = row.total_pages,
            }
        end
    end
    if #stats == 0 then
        cb(nil, _("无阅读统计数据"))
        return nil
    end
    return self._client:syncStatsAsync({
        books = books,
        stats = stats,
        device_id = "koreader",
    }, cb)
end

--- 一次拉取 Moon 账户的完整 page_stat 快照。
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return table|nil
function Source:pullStatsAsync(cb)
    return self._client:getStatsAsync(function(wire, err)
        if not wire then
            cb(nil, (type(err) == "table" and err.message) or err)
            return
        end
        local data = wire.data or wire
        local stats = data.stats or data.records or {}
        local rows = {}
        for _, item in ipairs(type(stats) == "table" and stats or {}) do
            local stable_id = item.book_filename or item.filename
            local start_time = tonumber(item.start_time or item.startTime)
            local duration = tonumber(item.duration)
            if stable_id and stable_id ~= "" and start_time and duration and duration > 0 then
                rows[#rows + 1] = {
                    source_id = self.id,
                    stable_id = stable_id,
                    record_type = "page",
                    page = tonumber(item.page) or 0,
                    start_time = start_time,
                    duration = duration,
                    total_pages = tonumber(item.total_pages or item.totalPages or item.pages) or 0,
                }
            end
        end
        cb({ rows = rows, replace = { mode = "all_synced" } })
    end)
end

--- 按 stable_id 整体上传某本书的划线/书签。
--- Moon 的注解接口是整本覆盖语义，annotations 必须是该书的完整集合。
---@param identity BookIdentity
---@param annotations table[] KOReader 注解数组
---@param cb fun(data: table|nil, err: string|nil)
---@return table|nil
function Source:pushNotesAsync(identity, annotations, cb)
    if type(identity) ~= "table" or type(identity.stable_id) ~= "string"
        or identity.stable_id == "" or type(annotations) ~= "table" then
        cb(nil, _("无效的注解数据"))
        return nil
    end
    return self._client:syncAnnotationsAsync({
        filename = identity.stable_id,
        device_id = "koreader",
        annotations = annotations,
    }, function(wire, err)
        if wire then
            cb(wire)
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

--- 拉取某本书的划线/书签；远端没有注解字段时按空数组处理。
---@param identity BookIdentity
---@param cb fun(annotations: table[]|nil, err: string|nil)
---@return table|nil
function Source:pullNotesAsync(identity, cb)
    return self._client:getAnnotationsAsync(identity.stable_id, function(wire, err)
        if not wire then
            cb(nil, (type(err) == "table" and err.message) or err)
            return
        end
        local data = wire.data or wire
        local annotations = data.annotations
        cb(type(annotations) == "table" and annotations or {}, nil, { authoritative = true })
    end)
end

--- 拉取云端阅读进度；wire 映射不出有效位置时按「进度为空」失败。
---@param identity BookIdentity
---@param cb fun(pos: ProgressPosition|nil, err: string|nil)
---@return table|nil
function Source:getProgressAsync(identity, cb)
    return self._client:getProgressAsync(identity.stable_id, function(wire, err)
        if not wire then
            cb(nil, (type(err) == "table" and err.message) or err)
            return
        end
        if type(wire) == "table"
            and ((wire.code ~= nil and wire.data == nil)
                or (type(wire.data) == "table" and next(wire.data) == nil)) then
            cb(nil, nil, { empty = true })
            return
        end
        local pos = Mapper.progress(wire)
        if pos then
            cb(pos)
        else
            cb(nil, _("进度为空"))
        end
    end)
end

--- 上报阅读进度：百分比、章节序号、页码与 locator 一起发。
---@param identity BookIdentity
---@param pos ProgressPosition|nil 缺省视为空位置（百分比 0）
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return table|nil
function Source:putProgressAsync(identity, pos, cb)
    pos = pos or {}
    local frac = ProgressPosition.clampFraction(pos.fraction)
    -- locator 是唯一能跨设备对齐的坐标：百分比会随字号排版漂移。
    -- 不发它的话，mapper 拉回来的 locator 永远是 nil，恢复位置只能靠百分比。
    return self._client:updateProgressAsync({
        filename = identity.stable_id,
        frac = frac,
        spine = pos.chapter_idx or 0,
        page = pos.page or 0,
        offset = pos.extra and pos.extra.offset or 0,
        percent = string.format("%.2f", frac * 100) .. "%",
        locator = pos.locator,
    }, function(wire, err)
        if wire then
            cb(true)
        else
            cb(nil, (type(err) == "table" and err.message) or err)
        end
    end)
end

return Moon
