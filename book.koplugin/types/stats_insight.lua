---@meta

--- 阅读洞察整页数据（总览 KPI + 日历）。
--- 由 `Contract.normalizeInsight` 从 moon wire 产出。
---@class StatsInsight
---@field has_data boolean 是否有统计；false 时 insight 页显示空态
---@field total StatsTotal 总览 KPI
---@field calendar StatsCalendar 月历与日书单

--- readingInsight 返回包装；失败走第二返回值 err。
---@class BookInsightResult
---@field data StatsInsight|nil
