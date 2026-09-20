--[[--
本地目录唯一读入口：books 提供书库列表，pending_progress 提供最近阅读，
reading_stats 提供统计。

约定：
  - UI 查询经 SourceBase 的本地方法到达此处
  - 远端源只负责 sync* 把变更写入本地库；读路径与源协议解耦
  - library_mixed 打开时，列表/筛选/最近/洞察跨已启用源聚合；
    每本书仍带真实 source_id，阅读打开走属主源

@module koplugin.book.catalog
--]]

--- 图书馆 / 书城列表查询参数。
--- 未使用的筛选项传 nil 或空串；源不支持的项可忽略。
---@class BookListOpts
---@field page number|nil 页码，从 1 起
---@field page_size number|nil 每页条数（须与网格容量一致）
---@field search string|nil 关键词搜索
---@field scope number|nil 书城搜索范围（wechat：0 全部 / 10 电子书 / 16 网文 / 14 听书 等）
---@field series string|nil 按系列筛选
---@field category string|nil 按分类筛选
---@field uncategorized boolean|nil 只查询 category 为 NULL/空串的未分类桶
---@field unseries boolean|nil 只查询 series 为 NULL/空串的无系列桶
---@field read_status "read"|"unread"|nil 按独立阅读状态筛选
---@field source_id string|nil 混合模式下按书行所属源筛选
---@field force boolean|nil 强制重扫、忽略扫描缓存（本地源手动刷新）
---@field sort "title"|"author"|"recent_read"|"recent_added"|nil 排序字段
---@field sort_desc boolean|nil 是否降序

--- 列表响应（图书馆 / 书城 / 最近阅读）。
---@class BookListResult
---@field count number|nil 符合条件的总条数（分页用）
---@field data Book[]|nil 本页书籍；无数据时为空表

require("l10n").apply()

local _ = require("gettext")

local Catalog = {}

--- 构造标准 BookListResult。
---@param books Book[]|nil
---@param count number|nil
---@return BookListResult
function Catalog.listResult(books, count)
    local data = books or {}
    return {
        data = data,
        count = tonumber(count) or #data,
    }
end

--- 简易模板替换（离线测试的 LuaJIT 无 table.pack，不能依赖 ffi/util.template）。
---@param fmt string
---@param a1 any
---@param a2 any
---@return string
local function T(fmt, a1, a2)
    local s = tostring(fmt)
    if a1 ~= nil then s = s:gsub("%%1", tostring(a1), 1) end
    if a2 ~= nil then s = s:gsub("%%2", tostring(a2), 1) end
    return s
end

--- 时长格式化（秒 → 「N小时N分钟」/「N分钟」）。
---@param seconds number|nil
---@return string
function Catalog.formatDuration(seconds)
    local sec = math.floor(tonumber(seconds) or 0)
    if sec <= 0 then
        return T(_("%1分钟"), 0)
    end
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    if h > 0 then
        return T(_("%1小时%2分钟"), h, m)
    end
    return T(_("%1分钟"), math.max(1, m))
end

--- 展示查询范围：混合 → 已启用源 id 列表；否则原样返回 preferred_id。
--- 单元素列表收成字符串，SQL 走 `=` 而不是 `IN`。
---@param preferred_id string|string[]|nil
---@return string|string[]|nil
function Catalog.libraryScope(preferred_id)
    if not require("utils.settings").libraryMixed() then
        return preferred_id
    end
    local ids = {}
    for _, meta in ipairs(require("source.registry").listEnabled()) do
        ids[#ids + 1] = meta.id
    end
    if #ids == 1 then
        return ids[1]
    end
    return ids
end

--- books 表行 → Book。
---@param row table|nil
---@param source_id string|nil 行内缺 source_id 时使用
---@return Book|nil
local function toBook(row, source_id)
    if type(row) ~= "table" or type(row.stable_id) ~= "string" or row.stable_id == "" then
        return nil
    end
    return {
        source_id = row.source_id or source_id,
        stable_id = row.stable_id,
        title = row.title,
        authors = row.authors,
        intro = row.intro,
        category = row.category,
        series = row.series,
        percent = tonumber(row.percent) or 0,
        read_state = tonumber(row.read_state) or 0,
        path = row.path,
        chapter_idx = row.chapter_idx,
        chapter_title = row.chapter_title,
        page = row.page,
        total_pages = row.total_pages,
    }
end

--- books 表行 → BookListResult。
---@param rows table[]|nil
---@param count number|nil
---@param source_id string|nil 行内缺 source_id 时使用
---@return BookListResult
function Catalog.toList(rows, count, source_id)
    local books = {}
    for _, row in ipairs(rows or {}) do
        local book = toBook(row, source_id)
        if book then
            books[#books + 1] = book
        end
    end
    return Catalog.listResult(books, tonumber(count) or #books)
end

--- 阅读统计聚合 → StatsInsight。
---@param source_id string|string[] 单源字符串或多源列表；多源一律按日书单（不用微信周桶）
---@param summary table|nil
---@param daily table[]|nil
---@param daily_books table[]|nil
---@param weekly_books table[]|nil
---@return StatsInsight
function Catalog.toInsight(source_id, summary, daily, daily_books, weekly_books)
    local has_data = (tonumber(summary and summary.total_seconds) or 0) > 0
    local days = {}
    for _, d in ipairs(daily or {}) do
        if type(d.ymd) == "string" then
            days[d.ymd] = {
                duration_seconds = tonumber(d.seconds) or 0,
                duration_text = Catalog.formatDuration(d.seconds),
                books = {},
            }
        end
    end
    local BookDB = require("db.book")
    local week_scope = source_id == "wechat"
    local book_rows = week_scope and (weekly_books or {}) or (daily_books or {})
    local function appendBook(day, b)
        if day and type(b.stable_id) == "string" and b.stable_id ~= "" then
            local sid = b.source_id or source_id
            local meta = type(sid) == "string" and BookDB.get(sid, b.stable_id) or nil
            local max_total = tonumber(b.max_total_pages) or 0
            local percent = 0
            if max_total > 0 then
                percent = math.floor((tonumber(b.max_page) or 0) * 100 / max_total + 0.5)
                if percent > 100 then
                    percent = 100
                end
            elseif week_scope and type(sid) == "string" then
                local progress = require("db.progress").get(sid, b.stable_id)
                if progress then
                    percent = math.floor((tonumber(progress.fraction) or 0) * 100 + 0.5)
                end
            end
            local title = meta and meta.title or nil
            if not title or title == "" then
                title = (b.stable_id:match("([^/]+)$") or b.stable_id):gsub("%.[^.]+$", "")
            end
            day.books[#day.books + 1] = {
                source_id = sid,
                stable_id = b.stable_id,
                title = title,
                authors = meta and meta.authors or nil,
                percent = percent,
                duration_seconds = tonumber(b.seconds) or 0,
                duration_text = Catalog.formatDuration(b.seconds),
            }
        end
    end
    local weeks = {}
    if week_scope then
        for _, b in ipairs(book_rows) do
            if type(b.week_ymd) == "string" then
                weeks[b.week_ymd] = weeks[b.week_ymd] or { books = {} }
                appendBook(weeks[b.week_ymd], b)
            end
        end
    else
        for _, b in ipairs(book_rows) do
            appendBook(type(b.ymd) == "string" and days[b.ymd] or nil, b)
        end
    end
    local total_seconds = tonumber(summary and summary.total_seconds) or 0
    return {
        has_data = has_data,
        total = {
            has_data = has_data,
            total_pages = tonumber(summary and summary.total_pages) or 0,
            total_text = Catalog.formatDuration(total_seconds),
            last7_text = Catalog.formatDuration(summary and summary.last7_seconds),
            longest_day_text = Catalog.formatDuration(summary and summary.longest_day_seconds),
        },
        calendar = {
            initial_ym = os.date("%Y-%m"),
            days = days,
            book_scope = week_scope and "week" or "day",
            weeks = week_scope and weeks or nil,
        },
    }
end

---@param cb function
---@param ... any
---@return { cancel: fun() }
local function defer(cb, ...)
    local cancelled = false
    local args = { ... }
    require("ui/uimanager"):nextTick(function()
        if not cancelled then
            cb(unpack(args))
        end
    end)
    return { cancel = function()
            cancelled = true
        end }
end

---@param scope string|string[]|nil
---@return boolean
local function validScope(scope)
    return type(scope) == "string" and scope ~= ""
        or type(scope) == "table" and #scope > 0
end

--- 图书馆分页 / 搜索 / 筛选（直查 books 表）。
---@param source_id string
---@param opts BookListOpts|nil
---@param cb fun(data: BookListResult|nil, err: string|nil)
---@return { cancel: fun() }
function Catalog.listLibraryAsync(source_id, opts, cb)
    opts = opts or {}
    local page = math.max(1, tonumber(opts.page) or 1)
    local page_size = math.max(1, tonumber(opts.page_size) or 24)
    local cancelled = false
    require("ui/uimanager"):nextTick(function()
        if cancelled then
            return
        end
        local scope = Catalog.libraryScope(source_id)
        if not validScope(scope) then
            cb(nil, "invalid source_id")
            return
        end
        ---@cast scope string|string[]
        local rows, count = require("db.book").listBySource(scope, {
            category = opts.category,
            uncategorized = opts.uncategorized,
            series = opts.series,
            unseries = opts.unseries,
            search = opts.search,
            read_status = opts.read_status,
            source_id = opts.source_id,
            sort = opts.sort,
            sort_desc = opts.sort_desc,
            limit = page_size,
            offset = (page - 1) * page_size,
        })
        cb(Catalog.toList(rows, count, type(scope) == "string" and scope or nil))
    end)
    return { cancel = function()
            cancelled = true
        end }
end

--- 分类 / 系列 /（混合时）数据源筛选项。
---@param source_id string
---@param cb fun(data: BookFiltersResult|nil, err: string|nil)
---@return { cancel: fun() }
function Catalog.filtersAsync(source_id, cb)
    return defer(function()
        local scope = Catalog.libraryScope(source_id)
        if not validScope(scope) then
            cb(nil, "invalid source_id")
            return
        end
        ---@cast scope string|string[]
        local BookDB = require("db.book")
        local data = {
            category = BookDB.categoriesBySource(scope),
            category_counts = BookDB.categoryCountsBySource(scope),
            series = BookDB.seriesBySource(scope),
            series_counts = BookDB.seriesCountsBySource(scope),
            read_counts = BookDB.readStatusCountsBySource(scope),
        }
        -- 仅多源混合时给出源分组；顺序跟已启用列表，册数来自聚合。
        if type(scope) == "table" then
            local by_id = {}
            for _, row in ipairs(BookDB.sourceCountsBySource(scope)) do
                by_id[row.source_id] = row.count
            end
            local Registry = require("source.registry")
            local source_counts = {}
            for _, meta in ipairs(Registry.listEnabled()) do
                local name = meta.name
                if type(name) ~= "string" or name == "" then
                    name = meta.id
                end
                source_counts[#source_counts + 1] = {
                    source_id = meta.id,
                    name = name,
                    count = by_id[meta.id] or 0,
                }
            end
            data.source_counts = source_counts
        end
        cb({ data = data })
    end)
end

--- 首页书架：第一本当前阅读，其余在读；source 无效时带错误文案。
---@param source_id string|nil
---@param limit number|nil
---@return Book|nil
---@return Book[]
---@return string|nil
function Catalog.recentShelf(source_id, limit)
    local scope = Catalog.libraryScope(source_id)
    if not validScope(scope) then
        return nil, {}, require("gettext")("当前数据源不可用")
    end
    ---@cast scope string|string[]
    local rows = Catalog.recentBooks(source_id, limit or 24)
    local recent = rows[1]
    local skip_source = recent and recent.source_id
    local skip = recent and recent.stable_id
    local reading = {}
    for i = 1, #rows do
        local book = rows[i]
        if not (book.stable_id == skip and book.source_id == skip_source) then
            reading[#reading + 1] = book
        end
    end
    return recent, reading, nil
end

--- 最近阅读同步快照：进度决定准入、顺序和阅读位置，books 只补书库元数据。
---@param source_id string|string[]|nil
---@param limit number|nil
---@return Book[]
function Catalog.recentBooks(source_id, limit)
    local scope = Catalog.libraryScope(source_id)
    if not validScope(scope) then
        return {}
    end
    ---@cast scope string|string[]
    local progress_rows = require("db.progress").recent(scope, limit)
    local books = {}
    local BookDB = require("db.book")
    for _, progress in ipairs(progress_rows) do
        -- 按 (source_id, stable_id) 取元数据，避免跨源 stable_id 碰撞。
        local meta = BookDB.get(progress.source_id, progress.stable_id)
        local book = toBook(meta, progress.source_id)
        if book then
            book.percent = math.floor((tonumber(progress.fraction) or 0) * 100 + 0.5)
            book.chapter_idx = progress.chapter_idx
            book.chapter_title = progress.chapter_title
            book.page = progress.page
            book.total_pages = progress.total_pages
            books[#books + 1] = book
        end
    end
    return books
end

--- 最近阅读（仅按 pending_progress.updated_at 倒序）。
---@param source_id string
---@param limit number|nil
---@param cb fun(data: BookListResult|nil, err: string|nil)
---@return { cancel: fun() }
function Catalog.recentBooksAsync(source_id, limit, cb)
    return defer(function()
        local scope = Catalog.libraryScope(source_id)
        if not validScope(scope) then
            cb(nil, "invalid source_id")
            return
        end
        ---@cast scope string|string[]
        local rows = Catalog.recentBooks(source_id, limit or 24)
        cb(Catalog.toList(rows, nil, type(scope) == "string" and scope or nil))
    end)
end

--- 阅读洞察（reading_stats 聚合）。
---@param source_id string
---@param cb fun(data: BookInsightResult|nil, err: string|nil)
---@return { cancel: fun() }
function Catalog.readingInsightAsync(source_id, cb)
    return defer(function()
        local scope = Catalog.libraryScope(source_id)
        if not validScope(scope) then
            cb(nil, "invalid source_id")
            return
        end
        ---@cast scope string|string[]
        local StatsDB = require("db.stats")
        local weekly = scope == "wechat" and StatsDB.weeklyBooksBySource(scope) or nil
        cb({
            data = Catalog.toInsight(
                scope,
                StatsDB.summaryBySource(scope),
                StatsDB.dailyBySource(scope),
                StatsDB.dailyBooksBySource(scope),
                weekly
            ),
        })
    end)
end

return Catalog
