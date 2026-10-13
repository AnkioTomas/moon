--[[--
统计页第 3 页：连续记录、年度总计和每月阅读时长图表。

@module koplugin.book.desktop.pages.insight.records
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Chart = require("ui.widgets.chart")
local Common = require("desktop.detail.common")
local Theme = require("ui.themes")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookInsightRecords
local Records = {}

local Catalog = require("book.catalog")

--- 累计阅读小时数的里程碑阶梯。
local MILESTONE_HOURS = { 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000 }

--- 下一档里程碑卡片：还没到的最低一档；全部达成时停在最高档。
---@param total_seconds number
---@return { value: string, label: string }
local function milestone(total_seconds)
    for _idx, hours in ipairs(MILESTONE_HOURS) do
        if total_seconds < hours * 3600 then
            return {
                value = T(_("%1小时"), hours),
                label = T(_("距下一里程碑 %1"), Catalog.formatDuration(hours * 3600 - total_seconds)),
            }
        end
    end
    return { value = T(_("%1小时"), MILESTONE_HOURS[#MILESTONE_HOURS]), label = _("里程碑全部达成") }
end

--- 解析日历日期键。
---@param ymd string YYYY-MM-DD 日期键。
---@return number|nil, number|nil, number|nil
local function parseYmd(ymd)
    local y, m, d = ymd:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not y or not m or not d or m < 1 or m > 12 or d < 1 or d > 31 then
        return nil, nil, nil
    end
    return y, m, d
end

--- 将日期转换为不受夏令时影响的 Gregorian 日序号。
---@param year number 年。
---@param month number 月。
---@param day number 日。
---@return number
local function dayNumber(year, month, day)
    if month <= 2 then year, month = year - 1, month + 12 end
    return 365 * year + math.floor(year / 4) - math.floor(year / 100) + math.floor(year / 400)
        + math.floor((153 * (month - 3) + 2) / 5) + day
end

--- 返回已排序整数集合中最长的连续区间。
---@param values number[] 已排序且去重的整数。
---@return number
local function longestRun(values)
    local best, run, previous = 0, 0, nil
    for _idx, value in ipairs(values) do
        if previous and value == previous + 1 then run = run + 1 else run = 1 end
        best = math.max(best, run)
        previous = value
    end
    return best
end

--- 从日历按年、周、月汇总连续记录和柱状图数据。
---@param state table 统计状态，包含 calendar.days。
---@return table
local function aggregate(state)
    local year = tonumber(os.date("%Y"))
    local year_seconds, year_days = 0, {}
    local month_seconds = {}
    for month = 1, 12 do month_seconds[month] = 0 end
    local all_weeks, all_months = {}, {}
    local week_seconds, day_seconds = {}, {}
    local pages_record = 0

    for ymd, info in pairs(state.calendar.days) do
        local y, m, d = parseYmd(ymd)
        local seconds = info.duration_seconds
        if y and seconds > 0 then
            local yy, mm, dd = assert(y), assert(m), assert(d)
            ---@cast yy integer
            ---@cast mm integer
            ---@cast dd integer
            local day = dayNumber(yy, mm, dd)
            local wday = tonumber(os.date("%w", os.time{ year = yy, month = mm, day = dd, hour = 12 })) or 0
            local monday = day - ((wday + 6) % 7)
            local week = math.floor(monday / 7)
            local month = yy * 12 + mm
            all_weeks[week] = true
            all_months[month] = true
            week_seconds[week] = (week_seconds[week] or 0) + seconds
            day_seconds[day] = (day_seconds[day] or 0) + seconds
            pages_record = math.max(pages_record, info.pages or 0)
            if yy == year then
                year_seconds = year_seconds + seconds
                month_seconds[mm] = month_seconds[mm] + seconds
                year_days[day] = true
            end
        end
    end

    --- 将集合键排序成数组。
    ---@param set table 数字键集合。
    ---@return number[]
    local function sortedKeys(set)
        local keys = {}
        for key in pairs(set) do keys[#keys + 1] = key end
        table.sort(keys)
        return keys
    end
    --- 返回数值表最大值。
    ---@param values table 数值表。
    ---@return number
    local function maxValue(values)
        local best = 0
        for _key, value in pairs(values) do best = math.max(best, value) end
        return best
    end

    return {
        year = year,
        year_seconds = year_seconds,
        year_streak = longestRun(sortedKeys(year_days)),
        month_seconds = month_seconds,
        week_streak = longestRun(sortedKeys(all_weeks)),
        month_streak = longestRun(sortedKeys(all_months)),
        week_record = maxValue(week_seconds),
        day_record = maxValue(day_seconds),
        pages_record = pages_record,
    }
end

--- 将指标卡片排成一行。
---@param items table[] 每项包含 value 和 label。
---@param width number 行宽。
---@param gap number 卡片间距。
---@return table, number 行控件和高度。
local function recordRow(items, width, gap)
    local card_w = math.floor((width - gap * (#items - 1)) / #items)
    local row, row_h = HorizontalGroup:new{ align = "center" }, 0
    for i, item in ipairs(items) do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        local card, card_h = Common.kpiCard(card_w, item.value, item.label)
        row_h = math.max(row_h, card_h)
        table.insert(row, card)
    end
    return row, row_h
end

--- 构建当年每月阅读时长柱状图。
---@param stats table aggregate 的结果。
---@param width number 图表宽度。
---@param height number 图表高度。
---@param gap number 柱间距。
---@return table
local function monthlyChart(stats, width, height, gap)
    local points = {}
    for month = 1, 12 do
        points[#points + 1] = {
            value = stats.month_seconds[month] or 0,
            label = T(_("%1月"), month),
        }
    end
    return Chart.bars({
        points = points,
        width = width,
        height = height,
        gap = gap,
    })
end

--- 构建连续记录页。
---@param state table 统计状态。
---@param width number 内容宽度。
---@param avail_h number 可用高度。
---@return table
function Records:build(state, width, avail_h)
    local stats = aggregate(state)
    local t = Theme.current()
    local gap, xs = Theme.px(t.space.sm), Theme.px(t.space.xs)
    local col = VerticalGroup:new{ align = "left" }
    local used = 0
    --- 追加控件并累计高度。
    ---@param widget table 子控件。
    ---@param widget_h number 控件高度。
    local function push(widget, widget_h)
        table.insert(col, widget)
        used = used + (widget_h or 0)
    end

    local year_row, year_h = recordRow({
        { value = Catalog.formatDuration(stats.year_seconds), label = _("今年总阅读时长") },
        { value = T(_("%1天"), stats.year_streak), label = _("今年连续阅读天数") },
    }, width, gap)
    push(year_row, year_h)
    push(VerticalSpan:new{ width = gap }, gap)
    local streak_row, streak_h = recordRow({
        { value = T(_("%1周"), stats.week_streak), label = _("周连续") },
        { value = T(_("%1个月"), stats.month_streak), label = _("月连续") },
    }, width, gap)
    push(streak_row, streak_h)
    push(VerticalSpan:new{ width = gap }, gap)
    local record_row, record_h = recordRow({
        { value = Catalog.formatDuration(stats.week_record), label = _("每周记录") },
        { value = Catalog.formatDuration(stats.day_record), label = _("每日记录") },
    }, width, gap)
    push(record_row, record_h)
    push(VerticalSpan:new{ width = gap }, gap)
    local mile_row, mile_h = recordRow({
        { value = tostring(stats.pages_record), label = _("单日最多页数") },
        milestone(state.total and state.total.total_seconds or 0),
    }, width, gap)
    push(mile_row, mile_h)
    push(VerticalSpan:new{ width = gap }, gap)
    local title = Text.line("caption", T(_("%1年每月阅读时长"), stats.year), { width = width, color = t.color.muted })
    push(title, title:getSize().h)
    push(VerticalSpan:new{ width = xs }, xs)
    local chart_h = math.max(Theme.px(48), math.min(Theme.px(220), avail_h - used))
    push(monthlyChart(stats, width, chart_h, xs), chart_h)
    return col
end

return Records
