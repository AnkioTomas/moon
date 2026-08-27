--[[--
首页阅读统计聚合（本地 reading_stats）。

@module koplugin.book.ui.desktop.home.stats
--]]

local Catalog = require("book.catalog")
local StatsDB = require("utils.db.stats")

local HomeStats = {}

--- 当前连续阅读天数：今日有读从今天计，否则从昨天计。
---@param daily table[] { ymd, seconds }
---@return number
function HomeStats.currentStreak(daily)
    local day_set = {}
    for i, row in ipairs(daily or {}) do
        if type(row.ymd) == "string" and (tonumber(row.seconds) or 0) > 0 then
            day_set[row.ymd] = true
        end
    end
    local today = os.date("%Y-%m-%d")
    local cursor = os.time()
    if not day_set[today] then
        cursor = cursor - 86400
    end
    local streak = 0
    while true do
        local ymd = os.date("%Y-%m-%d", cursor)
        if not day_set[ymd] then break end
        streak = streak + 1
        cursor = cursor - 86400
    end
    return streak
end

--- 按源汇总首页三卡指标。
---@param source_id string
---@return table
function HomeStats.summarize(source_id)
    local summary = StatsDB.summaryBySource(source_id)
    local daily = StatsDB.dailyBySource(source_id)
    local today_ymd = os.date("%Y-%m-%d")
    local today_seconds = 0
    for i, row in ipairs(daily) do
        if row.ymd == today_ymd then
            today_seconds = tonumber(row.seconds) or 0
            break
        end
    end
    return {
        streak = HomeStats.currentStreak(daily),
        total_text = Catalog.formatDuration(summary.total_seconds),
        today_text = Catalog.formatDuration(today_seconds),
    }
end

return HomeStats
