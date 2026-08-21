--[[--
统计页第 3 页：连续记录、年度总计和每月阅读时长图表。

@module koplugin.book.ui.desktop.insight.records
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local Surface = require("ui.components.surface")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template

local Records = {}

--- 创建灰色弱化文案。
---@param text string 文案。
---@param width number 最大宽度。
---@param size number|nil 字号。
---@return table
local function muted(text, width, size)
    return TextWidget:new{
        text = text,
        face = UI.face("xx_smallinfofont", size or 14),
        max_width = width,
        fgcolor = UI.muted(),
    }
end

--- 将秒数格式化为统计页短时长文案。
---@param seconds number|nil 阅读秒数。
---@return string
local function formatSeconds(seconds)
    local sec = math.floor(tonumber(seconds) or 0)
    if sec <= 0 then return T(_("%1分钟"), 0) end
    local hours = math.floor(sec / 3600)
    local minutes = math.floor((sec % 3600) / 60)
    if hours > 0 then return T(_("%1小时%2分钟"), hours, minutes) end
    return T(_("%1分钟"), math.max(1, minutes))
end

--- 解析日历日期键。
---@param ymd string|nil YYYY-MM-DD 日期键。
---@return number|nil, number|nil, number|nil
local function parseYmd(ymd)
    if type(ymd) ~= "string" then return nil, nil, nil end
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
    for _, value in ipairs(values) do
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

    for ymd, info in pairs((state.calendar and state.calendar.days) or {}) do
        local y, m, d = parseYmd(ymd)
        local seconds = tonumber(info and info.duration_seconds) or 0
        if y and seconds > 0 then
            local day = dayNumber(y, m, d)
            local wday = tonumber(os.date("%w", os.time{ year = y, month = m, day = d, hour = 12 })) or 0
            local monday = day - ((wday + 6) % 7)
            local week = math.floor(monday / 7)
            local month = y * 12 + m
            all_weeks[week] = true
            all_months[month] = true
            week_seconds[week] = (week_seconds[week] or 0) + seconds
            day_seconds[day] = (day_seconds[day] or 0) + seconds
            if y == year then
                year_seconds = year_seconds + seconds
                month_seconds[m] = month_seconds[m] + seconds
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
        for _, value in pairs(values) do best = math.max(best, value) end
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
    }
end

--- 构建连续记录指标卡片。
---@param width number 卡片宽度。
---@param value string 指标值。
---@param label string 指标名称。
---@return table, number 卡片控件和高度。
local function recordCard(width, value, label)
    local pad = UI.sz(8)
    local inner_w = math.max(1, width - pad * 2)
    local value_widget = TextWidget:new{
        text = tostring(value), face = UI.face("cfont", 15), max_width = inner_w,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local label_widget = TextWidget:new{
        text = label, face = UI.face("xx_smallinfofont", 11), max_width = inner_w,
        fgcolor = UI.muted(),
    }
    local height = pad * 2 + value_widget:getSize().h
        + UI.sz(4) + label_widget:getSize().h
    return Surface.card(CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = height - pad * 2 },
        VerticalGroup:new{ align = "center", value_widget, VerticalSpan:new{ width = UI.sz(4) }, label_widget },
    }, {
        width = width,
        height = height,
        padding = pad,
        shadow = true,
    }), height
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
        local card, card_h = recordCard(card_w, item.value, item.label)
        row_h = math.max(row_h, card_h)
        table.insert(row, card)
    end
    return row, row_h
end

--- 构建当年每月阅读时长柱状图。
---@param stats table aggregate 的结果。
---@param width number 图表宽度。
---@param height number 图表高度。
---@return table
local function monthlyChart(stats, width, height)
    local gap = UI.sz(4)
    local col_w = math.max(1, math.floor((width - gap * 11) / 12))
    local label_h = UI.sz(18)
    local bar_h = math.max(UI.sz(24), height - label_h)
    local max_seconds = 0
    for month = 1, 12 do max_seconds = math.max(max_seconds, stats.month_seconds[month] or 0) end
    local row = HorizontalGroup:new{ align = "center" }
    for month = 1, 12 do
        if month > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        local seconds = stats.month_seconds[month] or 0
        local current_h = max_seconds > 0
            and math.max(UI.sz(2), math.floor(bar_h * seconds / max_seconds + 0.5)) or UI.line()
        local bar = LineWidget:new{
            background = seconds > 0 and Blitbuffer.COLOR_BLACK or UI.track(),
            dimen = Geom:new{ w = col_w, h = current_h },
        }
        local slot = BottomContainer:new{ dimen = Geom:new{ w = col_w, h = bar_h }, bar }
        local month_label = TextWidget:new{
            text = T(_("%1月"), month), face = UI.face("xx_smallinfofont", 10),
            max_width = col_w, fgcolor = UI.muted(),
        }
        table.insert(row, VerticalGroup:new{
            align = "center", slot, VerticalSpan:new{ width = UI.sz(3) },
            CenterContainer:new{ dimen = Geom:new{ w = col_w, h = label_h }, month_label },
        })
    end
    return row
end

--- 构建连续记录页。
---@param state table 统计状态。
---@param width number 内容宽度。
---@param avail_h number 可用高度。
---@return table
function Records.build(state, width, avail_h)
    local stats = aggregate(state)
    local gap = UI.sz(8)
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
        { value = formatSeconds(stats.year_seconds), label = _("今年总阅读时长") },
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
        { value = formatSeconds(stats.week_record), label = _("每周记录") },
        { value = formatSeconds(stats.day_record), label = _("每日记录") },
    }, width, gap)
    push(record_row, record_h)
    push(VerticalSpan:new{ width = gap }, gap)
    local title = muted(T(_("%1年每月阅读时长"), stats.year), width, 12)
    push(title, title:getSize().h)
    push(VerticalSpan:new{ width = UI.sz(4) }, UI.sz(4))
    local chart_h = math.max(UI.sz(48), math.min(UI.sz(220), avail_h - used))
    push(monthlyChart(stats, width, chart_h), chart_h)
    return col
end

return Records
