--[[--
Book (moon) 数据源门面
  client：HTTP wire（仅异步）
  mapper：wire → 领域对象

书架分页拉全量，先 Shelf.pushDeletes 再 reconcile；没有加书 API，本地新加的书推不上去。
进度、笔记、统计双向；统计 pull 是账户级快照，入库前按 replace 清掉已同步行，避免与本地页记录双计。

@module koplugin.book.source.moon
--]]

local Client = require("source.moon.client")
local Mapper = require("source.moon.mapper")
local SourceBase = require("source.base")
local Shelf = require("source.shelf")
local Progress = require("book.progress")
local _ = require("gettext")
local T = require("ffi/util").template

local Moon = {}

local BOOK_EXTENSIONS = {
    epub = true,
    pdf = true,
    cbz = true,
    cbr = true,
    mobi = true,
    azw = true,
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
    if ext == "mobi" or ext == "azw" or ext == "azw3" then
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
        scrape = false,
        edit = false,
        stats_pull = true,
    }
end

--- 是否已配置 Moon 源。
---@return boolean
function Source:configured()
    return self._client:configured()
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

    --- 缓存命中也在下一拍回调：调用方拿到句柄之后才会收到结果。
    ---@param local_path string
    local function registerLater(local_path)
        require("ui/uimanager"):nextTick(function()
            if not cancelled then register(local_path) end
        end)
        return { cancel = function() cancelled = true end }
    end

    local book = identity.book
    if not book or not book.path then
        book = require("book.books_db").get(identity.source_id, identity.stable_id) or book
    end
    local registered_path = book and book.path
    if registered_path and validBook(registered_path, identity.stable_id) then
        return registerLater(registered_path)
    end
    if validBook(path) then
        return registerLater(path)
    end
    os.remove(path)

    if not require("ui/network/manager"):isConnected() then
        require("ui/uimanager"):nextTick(function()
            if not cancelled then cb(nil, _("网络不可用，请先连接 Wi-Fi")) end
        end)
        return { cancel = function() cancelled = true end }
    end
    require("ui/uimanager"):nextTick(function()
        if cancelled then return end
        shareOpening(identity.stable_id, function(done)
            local title = book and book.title
                or (identity.stable_id:match("([^/\\]+)$") or identity.stable_id)
            dialog = require("ui.themes.widgets.progress_dialog"):new{
                title = title,
                dismissable = false,
            }
            dialog:show()
            dialog:set(_("正在下载…"))

            -- Request.download 自己写 .part 再原子改名，path 只会是完整文件。
            self._client:downloadBookAsync(identity.stable_id, path, function(bytes, total)
                if dialog and total and total > 0 then dialog:bytes(bytes, total) end
            end, function(ok, err)
                closeDialog()
                if not ok then
                    done(false, nil, err)
                    return
                end
                if not validBook(path) then
                    os.remove(path)
                    done(false, nil, _("下载文件校验失败"))
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
local function clearCaches()
    local Cache = require("http.cache")
    Cache.clear("/index/book/")
    Cache.clear("/index/stats/")
end

--- 构造 Moon 封面请求。
---@param identity BookIdentity
---@return BookCoverRequest|nil, string|nil
function Source:coverRequest(identity)
    return self._client:coverRequest(identity.stable_id)
end

--- 分页拉取完整 Moon 书架；先推本地待删，再对账。
---@param opts { force?: boolean, dirty_only?: boolean, on_progress?: fun(text: string|nil, done: integer|nil, total: integer|nil) }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }
function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    if opts.force then clearCaches() end
    local report = opts.on_progress or function(...) end
    local function removeOne(stable_id, done)
        return self._client:deleteBooksAsync({ stable_id }, function(res, err)
            if res then return done(res) end
            require("utils.log").warn("book moon delete failed", stable_id, err)
            -- 服务端已经没有这本书：删除目的已达成，撕掉墓碑，免得每次启动都重推。
            local gone = type(err) == "string" and (err:find("不存在", 1, true) or err:find("已删除", 1, true)
                or err:lower():find("not found", 1, true))
            if gone then require("http.cache").clear("/index/book/list") end
            done(gone and true or nil)
        end)
    end

    --- dirty_only：只推待删，不拉书架。
    if opts.dirty_only then
        return Shelf.pushDeletes(self.id, removeOne, report, function(n)
            cb({ pulled = 0, pushed = n, hidden = 0, conflicts = 0, skipped = false })
        end)
    end

    -- 全量拉取不吃 5 分钟列表缓存：旧页与新页混拼会漏书 / 复活已删的书。
    require("http.cache").clear("/index/book/list")
    local cancelled, job, delete_job = false, nil, nil
    local deleted_n = 0
    local page, page_size = 1, 200
    local books = {}
    local function pullPages()
        if cancelled then return end
        local query = { page = page, pageSize = page_size, search = "", series = "", category = "" }
        report(T(_("正在拉取书架（第 %1 页）"), page))
        job = self._client:listBooksAsync(query, function(wire, err)
            job = nil
            if cancelled then return end
            if not wire then cb(nil, err); return end
            local mapped = Mapper.list(wire)
            for _idx, book in ipairs(mapped.data) do books[#books + 1] = book end
            if #books < mapped.count and #wire.data > 0 then
                report(T(_("正在拉取书架（第 %1 页）"), page), #books, mapped.count)
                page = page + 1
                pullPages()
                return
            end
            report(T(_("正在写入书架（%1 本）"), #books))
            local result, rerr = Shelf.reconcile(self.id, books)
            if result then result.pushed = deleted_n end
            cb(result, rerr)
        end)
    end
    delete_job = Shelf.pushDeletes(self.id, removeOne, report, function(n)
        if cancelled then return end
        deleted_n = n
        pullPages()
    end)
    return { cancel = function()
        cancelled = true
        if job then job:cancel() end
        delete_job:cancel()
    end }
end

--- 把领域统计记录转换成 Moon 的上报协议。
--- 设备标识和 books/stats wire 字段属于 Source，不泄漏到 book.stats。
---@param rows table[]
---@param cb fun(data: table|nil, err: string|nil)
---@return table|nil
function Source:pushStatsAsync(rows, cb)
    local books, stats, seen = {}, {}, {}
    for _idx, row in ipairs(rows) do
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
            cb(nil, err)
            return
        end
        local rows = {}
        -- data.stats[] = { book_filename, start_time, duration, page, total_pages }，按书按天聚合
        for _idx, item in ipairs(wire.data.stats) do
            if item.duration > 0 then
                rows[#rows + 1] = {
                    source_id = self.id,
                    stable_id = item.book_filename,
                    record_type = "page",
                    page = item.page,
                    start_time = item.start_time,
                    duration = item.duration,
                    total_pages = item.total_pages,
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
    return self._client:syncAnnotationsAsync({
        filename = identity.stable_id,
        device_id = "koreader",
        annotations = annotations,
    }, cb)
end

--- 拉取某本书的划线/书签（服务端是该书的完整快照）。
---@param identity BookIdentity
---@param cb fun(annotations: table[]|nil, err: string|nil, meta: table|nil)
---@return table|nil
function Source:pullNotesAsync(identity, cb)
    return self._client:getAnnotationsAsync(identity.stable_id, function(wire, err)
        if not wire then
            cb(nil, err)
            return
        end
        cb(wire.data.annotations, nil, { authoritative = true })
    end)
end

--- 拉取云端阅读进度；云端没有进度时按 meta.empty 回调。
---@param identity BookIdentity
---@param cb fun(pos: ProgressPosition|nil, err: string|nil, meta: table|nil)
---@return table|nil
function Source:getProgressAsync(identity, cb)
    return self._client:getProgressAsync(identity.stable_id, function(wire, err)
        if not wire then
            cb(nil, err)
            return
        end
        local pos = Mapper.progress(wire)
        if pos then
            cb(pos)
        else
            cb(nil, nil, { empty = true })
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
        cb(wire and true or nil, err)
    end)
end

return Moon
