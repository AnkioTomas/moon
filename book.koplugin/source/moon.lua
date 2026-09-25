--[[--
Book (moon) 数据源门面
  client：HTTP wire（仅异步）
  mapper：wire → 领域对象

@module koplugin.book.source.moon
--]]

local Client = require("source.moon.client")
local Mapper = require("source.moon.mapper")
local SourceBase = require("source.base")
local Progress = require("book.progress")
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

--- 传输层错误可能是带 message 的表（Turbo），统一成可展示文案。
---@param err any
---@return any
local function errText(err)
    return (type(err) == "table" and err.message) or err
end

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
    }
end

--- 是否已配置 Moon 源。
---@return boolean
function Source:configured()
    return self._client:configured()
end

--- 删除：本地先标 deleted，能上网时再推云端真删。
---@param identity BookIdentity
---@param cb fun(ok: boolean, err: string|nil)
---@return table
function Source:deleteBookAsync(identity, cb)
    local Store = require("book.store")
    if not Store.markDeleted(self.id, identity.stable_id) then
        require("ui/uimanager"):nextTick(function()
            cb(false, _("删除本书失败"))
        end)
        return { cancel = function() end }
    end
    local cancelled, job = false, nil
    require("ui/uimanager"):nextTick(function()
        if not cancelled then cb(true) end
    end)
    require("ui/network/manager"):runWhenOnline(function()
        if cancelled then return end
        job = self._client:deleteBooksAsync({ identity.stable_id }, function(wire)
            if cancelled then return end
            if wire then Store.finalizeDeleted(self.id, identity.stable_id) end
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
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
            local ProgressbarDialog = require("ui/widget/progressbardialog")
            local dialog_total
            -- progress_max 只能在构造时给；先出无进度条的框，拿到 Content-Length 后换成带条的。
            ---@param total number|nil
            local function showDialog(total)
                closeDialog()
                dialog_total = total
                dialog = ProgressbarDialog:new{
                    title = _("正在下载…"),
                    subtitle = title,
                    progress_max = total,
                    refresh_time_seconds = 1,
                    dismissable = false,
                }
                dialog:show()
            end
            showDialog(nil)

            local temp_path = path .. ".part"
            self._client:downloadBookAsync(identity.stable_id, temp_path, function(bytes, total)
                if not dialog then return end
                if total and total > 0 and total ~= dialog_total then showDialog(total) end
                dialog:reportProgress(bytes)
            end, function(ok, err)
                closeDialog()
                if not ok then
                    os.remove(temp_path)
                    done(false, nil, errText(err))
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
            if not ok or type(local_path) ~= "string" then
                cb(nil, err or _("下载失败"))
                return
            end
            register(local_path)
        end)
    end)

    return { cancel = function()
            cancelled = true
            closeDialog()
        end }
end

--- 清空 Moon 书库/统计相关 HTTP 缓存。
function Source:clearCaches()
    local Request = require("http.request")
    Request.clearCache("/index/book/")
    Request.clearCache("/index/stats/")
end

--- 构造 Moon 封面请求。
---@param identity BookIdentity
---@return BookCoverRequest|nil, string|nil
function Source:coverRequest(identity)
    local req, err = self._client:coverRequest(identity.stable_id)
    if not req then
        return nil, errText(err)
    end
    return req
end

--- 串行推待删：成功撕墓碑才计入。
---@param self MoonSource
---@param on_done fun(deleted_n: integer)
---@return { cancel: fun() }|nil
local function pushPendingDeletes(self, on_done)
    local Store = require("book.store")
    local pending = require("db.book").pendingDeleteIds(self.id)
    if #pending == 0 then
        return nil
    end
    local cancelled, delete_job, deleted_n, index = false, nil, 0, 0
    local function nextDelete()
        if cancelled then return end
        index = index + 1
        if index > #pending then
            on_done(deleted_n)
            return
        end
        local stable_id = pending[index]
        delete_job = self._client:deleteBooksAsync({ stable_id }, function(wire)
            delete_job = nil
            if cancelled then return end
            if wire and Store.finalizeDeleted(self.id, stable_id) then
                deleted_n = deleted_n + 1
            end
            nextDelete()
        end)
    end
    nextDelete()
    return { cancel = function()
        cancelled = true
        if delete_job and delete_job.cancel then delete_job:cancel() end
    end }
end

--- 分页拉取完整 Moon 书架；先推本地待删，再对账。
---@param opts { force?: boolean, dirty_only?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }
function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    if opts.force then self:clearCaches() end
    local cancelled, job, delete_job = false, nil, nil
    local deleted_n = 0

    --- dirty_only：只推待删，不拉书架。
    if opts.dirty_only then
        delete_job = pushPendingDeletes(self, function(n)
            if cancelled then return end
            cb({
                pulled = 0, pushed = n, hidden = 0, conflicts = 0, skipped = false,
            })
        end)
        if not delete_job then
            require("ui/uimanager"):nextTick(function()
                if not cancelled then
                    cb({ pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = false })
                end
            end)
        end
        return { cancel = function()
            cancelled = true
            if delete_job and delete_job.cancel then delete_job:cancel() end
        end }
    end

    local page, page_size = 1, 200
    local books = {}
    local function pullPages()
        if cancelled then return end
        local query = { page = page, pageSize = page_size, search = "", series = "", category = "" }
        job = self._client:listBooksAsync(query, function(wire, err)
            job = nil
            if cancelled then return end
            if not wire then cb(nil, errText(err)); return end
            local mapped = Mapper.list(wire)
            for _, book in ipairs(mapped.data or {}) do books[#books + 1] = book end
            local count = tonumber(mapped.count) or #books
            if #books < count and #(mapped.data or {}) > 0 then
                page = page + 1
                pullPages()
                return
            end
            local result, rerr = require("book.store").reconcile(self.id, books)
            if result then result.pushed = deleted_n end
            cb(result, rerr)
        end)
    end
    delete_job = pushPendingDeletes(self, function(n)
        if cancelled then return end
        deleted_n = n
        pullPages()
    end)
    if not delete_job then
        pullPages()
    end
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job:cancel() end
        if delete_job and delete_job.cancel then delete_job:cancel() end
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
            cb(nil, errText(err))
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
            cb(nil, errText(err))
        end
    end)
end

--- 拉取某本书的划线/书签；远端没有注解字段时按空数组处理。
---@param identity BookIdentity
---@param cb fun(annotations: table[]|nil, err: string|nil, meta: table|nil)
---@return table|nil
function Source:pullNotesAsync(identity, cb)
    return self._client:getAnnotationsAsync(identity.stable_id, function(wire, err)
        if not wire then
            cb(nil, errText(err))
            return
        end
        local data = wire.data or wire
        local annotations = data.annotations
        cb(type(annotations) == "table" and annotations or {}, nil, { authoritative = true })
    end)
end

--- 拉取云端阅读进度；wire 映射不出有效位置时按「进度为空」失败。
---@param identity BookIdentity
---@param cb fun(pos: ProgressPosition|nil, err: string|nil, meta: table|nil)
---@return table|nil
function Source:getProgressAsync(identity, cb)
    return self._client:getProgressAsync(identity.stable_id, function(wire, err)
        if not wire then
            cb(nil, errText(err))
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
    local frac = Progress.clampFraction(pos.fraction)
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
            cb(nil, errText(err))
        end
    end)
end

return Moon
