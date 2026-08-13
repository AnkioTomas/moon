---@meta

---@class StatsCalendarDay
---@field duration_seconds number|nil
---@field duration_text string|nil
---@field books Book[]|nil

---@class StatsCalendar
---@field initial_ym string
---@field days table<string, StatsCalendarDay>
