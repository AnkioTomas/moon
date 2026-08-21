--[[--
本地 DB 行 → Book 映射（委托 book.catalog，保留本模块兼容旧测试入口）。

@module koplugin.book.source.local.mapper
--]]

local Catalog = require("book.catalog")

local Mapper = {}

Mapper.formatDuration = Catalog.formatDuration

--- books 表行 → BookListResult（图书馆分页结果）。
---@param rows table[]
---@param count number|nil
---@return BookListResult
function Mapper.list(rows, count)
    return Catalog.toList(rows, count, "local")
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
    return Catalog.toInsight("local", summary, daily, daily_books)
end

return Mapper
