--[[--
统计页的阅读时段图表（按小时、按星期）；不是独立页面，本月页画按小时，趋势页画按星期。

本机逐页记录 + 云端时段桶：云端按活动行起始整点归档（跨整点的活动行整体算起始小时），
与本机记录同一套合并口径（见 book.stats_db.hourlyBySource）。

@module koplugin.book.desktop.pages.insight.hours
--]]

local Chart = require("ui.widgets.chart")
local Theme = require("ui.themes")
local _ = require("gettext")

---@class BookInsightHours
local Hours = {}

local WEEKDAYS = { _("一"), _("二"), _("三"), _("四"), _("五"), _("六"), _("日") }

--- 日期键以 prefix 开头的日子按小时、按星期（周一在前）累加。
---@param days table<string, StatsCalendarDay>
---@param prefix string YYYY 或 YYYY-MM；空串 = 全部
---@return number[] by_hour 24 格
---@return number[] by_wday 7 格
---@return number total
function Hours.aggregate(days, prefix)
    local by_hour, by_wday, total = {}, {}, 0
    for h = 1, 24 do by_hour[h] = 0 end
    for d = 1, 7 do by_wday[d] = 0 end
    for ymd, info in pairs(days) do
        local y, m, d = ymd:match("^(%d+)%-(%d+)%-(%d+)$")
        if info.hours and y and ymd:sub(1, #prefix) == prefix then
            local wday = (os.date("*t", os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }) --[[@as osdate]]).wday
            local idx = (wday + 5) % 7 + 1
            for h = 1, 24 do
                local seconds = info.hours[h]
                by_hour[h] = by_hour[h] + seconds
                by_wday[idx] = by_wday[idx] + seconds
                total = total + seconds
            end
        end
    end
    return by_hour, by_wday, total
end

--- 24 小时柱图的点：只在 0 / 6 / 12 / 18 点标刻度，24 个标签挤不下。
---@param hours number[] 24 格秒数
---@return table[]
function Hours.points(hours)
    local points = {}
    for h = 1, 24 do
        points[h] = { value = hours[h], label = (h - 1) % 6 == 0 and tostring(h - 1) or "" }
    end
    return points
end

--- 按小时柱图；没有本机记录返回 nil。
---@param days table<string, StatsCalendarDay>
---@param prefix string
---@param width number
---@param height number
---@return table|nil
function Hours.hourChart(days, prefix, width, height)
    local by_hour, _by_wday, total = Hours.aggregate(days, prefix)
    if total <= 0 then return nil end
    return Chart.bars({ points = Hours.points(by_hour), width = width, height = height, gap = Theme.px(2) })
end

--- 按星期柱图（周一在前）；没有本机记录返回 nil。
---@param days table<string, StatsCalendarDay>
---@param width number
---@param height number
---@return table|nil
function Hours.weekdayChart(days, width, height)
    local _by_hour, by_wday, total = Hours.aggregate(days, "")
    if total <= 0 then return nil end
    local points = {}
    for d = 1, 7 do points[d] = { value = by_wday[d], label = WEEKDAYS[d] } end
    return Chart.bars({ points = points, width = width, height = height, gap = Theme.px(4) })
end

return Hours
