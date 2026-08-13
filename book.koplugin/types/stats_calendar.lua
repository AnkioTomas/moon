---@meta
--- 仅 EmmyLua 类型注释，运行时不要 require。

--- 日历某一天的阅读摘要。
---@class StatsCalendarDay
---@field duration_seconds number|nil 当日阅读秒数（>0 则日历格高亮）
---@field duration_text string|nil 当日时长文案（日详情标题）
---@field books Book[]|nil 当日读过的书（日详情书单）

--- 阅读日历（insight 页月历）。
---@class StatsCalendar
---@field initial_ym string 初始年月，格式 YYYY-MM
---@field days table<string, StatsCalendarDay> 键为 YYYY-MM-DD
