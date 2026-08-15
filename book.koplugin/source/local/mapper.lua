--[[--
本地 DB 行 → Book 映射

@module koplugin.book.source.local.mapper
--]]

local BookRef = require("types.book").BookRef
local BookListResult = require("types.book_list")
local _ = require("gettext")

local Mapper = {}

local SOURCE_ID = "local"

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
local function formatDuration(seconds)
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
---@return Book|nil
local function bookFromRow(row)
    if type(row) ~= "table" or type(row.stable_id) ~= "string" or row.stable_id == "" then
        return nil
    end
    return {
        ref = BookRef.new(SOURCE_ID, row.stable_id),
        title = row.title,
        authors = row.authors,
        intro = row.intro,
        category = row.category,
        series = row.series,
        percent = tonumber(row.percent) or 0,
    }
end

--- books 表行 → BookListResult（图书馆分页结果）。
---@param rows table[]
---@param count number|nil
---@return BookListResult
function Mapper.list(rows, count)
    local books = {}
    for _, row in ipairs(rows or {}) do
        local b = bookFromRow(row)
        if b then
            books[#books + 1] = b
        end
    end
    return BookListResult.new(books, tonumber(count) or #books)
end

--- opens 表最近阅读行 → BookListResult。
---@param rows table[]
---@return BookListResult
function Mapper.recent(rows)
    return Mapper.list(rows)
end

--- 阅读统计聚合 → StatsInsight（与 moon 源洞察结构对齐）。
---@param summary table StatsDB.summaryBySource 结果
---@param daily table[] StatsDB.dailyBySource 结果
---@param daily_books table[] StatsDB.dailyBooksBySource 结果
---@return StatsInsight
function Mapper.insight(summary, daily, daily_books)
    local has_data = (tonumber(summary and summary.total_seconds) or 0) > 0
    local days = {}
    for _, d in ipairs(daily or {}) do
        if type(d.ymd) == "string" then
            days[d.ymd] = {
                duration_seconds = tonumber(d.seconds) or 0,
                duration_text = formatDuration(d.seconds),
                books = {},
            }
        end
    end
    local BookDB = require("utils.db.book")
    for _, b in ipairs(daily_books or {}) do
        local day = type(b.ymd) == "string" and days[b.ymd] or nil
        if day and type(b.stable_id) == "string" and b.stable_id ~= "" then
            local ref = BookRef.new(SOURCE_ID, b.stable_id)
            local meta = BookDB.get(ref.source_id, ref.stable_id)
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
                ref = ref,
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
            total_text = formatDuration(total_seconds),
            last7_text = formatDuration(summary and summary.last7_seconds),
            longest_day_text = formatDuration(summary and summary.longest_day_seconds),
        },
        calendar = {
            initial_ym = os.date("%Y-%m"),
            days = days,
        },
    }
end

--- 由 BookRef 构造详情：优先 books 表缓存（含介绍），否则文件名。
---@param ref BookRef
---@return BookDetail
function Mapper.detailFromRef(ref)
    local cached = require("utils.db.book").get(ref.source_id, ref.stable_id)
    if cached and type(cached.title) == "string" and cached.title ~= "" then
        return {
            ref = ref,
            title = cached.title,
            authors = cached.authors,
            intro = cached.intro,
            category = cached.category,
            percent = 0,
        }
    end
    local title = ref.stable_id:match("([^/]+)$") or ref.stable_id
    title = title:gsub("%.[^.]+$", "")
    return {
        ref = ref,
        title = title,
        percent = 0,
    }
end

return Mapper
