--[[--
本地书库唯一读入口：按 source_id 查 books / reading_stats。

约定：
  - UI 查询经 SourceBase 的本地方法到达此处
  - 远端源只负责 sync* 把变更写入本地库；读路径与源协议解耦

@module koplugin.book.catalog
--]]

require("l10n").apply()

local BookListResult = require("types.book_list")
local _ = require("gettext")

local Catalog = {}

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

--- books 表行 → Book。
---@param row table
---@param source_id string
---@return Book|nil
local function toBook(row, source_id)
    if type(row) ~= "table" or type(row.stable_id) ~= "string" or row.stable_id == "" then
        return nil
    end
    return {
        source_id = source_id,
        stable_id = row.stable_id,
        title = row.title,
        authors = row.authors,
        intro = row.intro,
        category = row.category,
        series = row.series,
        percent = tonumber(row.percent) or 0,
    }
end

--- books 表行 → BookListResult。
---@param rows table[]|nil
---@param count number|nil
---@param source_id string
---@return BookListResult
function Catalog.toList(rows, count, source_id)
    local books = {}
    for _, row in ipairs(rows or {}) do
        local book = toBook(row, source_id)
        if book then
            books[#books + 1] = book
        end
    end
    return BookListResult.new(books, tonumber(count) or #books)
end

--- 阅读统计聚合 → StatsInsight。
---@param source_id string
---@param summary table|nil
---@param daily table[]|nil
---@param daily_books table[]|nil
---@return StatsInsight
function Catalog.toInsight(source_id, summary, daily, daily_books)
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
    local BookDB = require("utils.db.book")
    for _, b in ipairs(daily_books or {}) do
        local day = type(b.ymd) == "string" and days[b.ymd] or nil
        if day and type(b.stable_id) == "string" and b.stable_id ~= "" then
            local meta = BookDB.get(source_id, b.stable_id)
            local max_total = tonumber(b.max_total_pages) or 0
            local percent = 0
            if max_total > 0 then
                percent = math.floor((tonumber(b.max_page) or 0) * 100 / max_total + 0.5)
                if percent > 100 then
                    percent = 100
                end
            end
            local title = meta and meta.title or nil
            if not title or title == "" then
                title = (b.stable_id:match("([^/]+)$") or b.stable_id):gsub("%.[^.]+$", "")
            end
            day.books[#day.books + 1] = {
                source_id = source_id,
                stable_id = b.stable_id,
                title = title,
                authors = meta and meta.authors or nil,
                percent = percent,
            }
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
    return {
        cancel = function()
            cancelled = true
        end,
    }
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
        if type(source_id) ~= "string" or source_id == "" then
            cb(nil, "invalid source_id")
            return
        end
        local rows, count = require("utils.db.book").listBySource(source_id, {
            category = opts.category,
            series = opts.series,
            search = opts.search,
            limit = page_size,
            offset = (page - 1) * page_size,
        })
        cb(Catalog.toList(rows, count, source_id))
    end)
    return {
        cancel = function()
            cancelled = true
        end,
    }
end

--- 分类 / 系列筛选项。
---@param source_id string
---@param cb fun(data: BookFiltersResult|nil, err: string|nil)
---@return { cancel: fun() }
function Catalog.filtersAsync(source_id, cb)
    return defer(function()
        if type(source_id) ~= "string" or source_id == "" then
            cb(nil, "invalid source_id")
            return
        end
        local BookDB = require("utils.db.book")
        cb({
            data = {
                category = BookDB.categoriesBySource(source_id),
                series = BookDB.seriesBySource(source_id),
            },
        })
    end)
end

--- 最近阅读（books.last_open 倒序）。
---@param source_id string
---@param limit number|nil
---@param cb fun(data: BookListResult|nil, err: string|nil)
---@return { cancel: fun() }
function Catalog.recentBooksAsync(source_id, limit, cb)
    return defer(function()
        if type(source_id) ~= "string" or source_id == "" then
            cb(nil, "invalid source_id")
            return
        end
        local rows = require("utils.db.book").recentBySource(source_id, limit or 24)
        cb(Catalog.toList(rows, nil, source_id))
    end)
end

--- 阅读洞察（reading_stats 聚合）。
---@param source_id string
---@param cb fun(data: BookInsightResult|nil, err: string|nil)
---@return { cancel: fun() }
function Catalog.readingInsightAsync(source_id, cb)
    return defer(function()
        if type(source_id) ~= "string" or source_id == "" then
            cb(nil, "invalid source_id")
            return
        end
        local StatsDB = require("utils.db.stats")
        cb({
            data = Catalog.toInsight(
                source_id,
                StatsDB.summaryBySource(source_id),
                StatsDB.dailyBySource(source_id),
                StatsDB.dailyBooksBySource(source_id)
            ),
        })
    end)
end

return Catalog
