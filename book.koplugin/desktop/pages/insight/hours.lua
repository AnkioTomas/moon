--[[--
统计页第 4 页：阅读时段（按小时、按星期）。

只统计本机记录：云端同步来的只有按天的时长，不知道几点读的。

@module koplugin.book.desktop.pages.insight.hours
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Catalog = require("book.catalog")
local Chart = require("ui.widgets.chart")
local Common = require("desktop.detail.common")
local Theme = require("ui.themes")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookInsightHours
local Hours = {}

local WEEKDAYS = { _("一"), _("二"), _("三"), _("四"), _("五"), _("六"), _("日") }

--- 全部日子按小时、按星期（周一在前）累加。
---@param days table<string, StatsCalendarDay>
---@return number[] by_hour 24 格
---@return number[] by_wday 7 格
---@return number total
local function aggregate(days)
    local by_hour, by_wday, total = {}, {}, 0
    for h = 1, 24 do by_hour[h] = 0 end
    for d = 1, 7 do by_wday[d] = 0 end
    for ymd, info in pairs(days) do
        local y, m, d = ymd:match("^(%d+)%-(%d+)%-(%d+)$")
        if info.hours and y then
            local wday = os.date("*t", os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }).wday
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

--- 构建阅读时段页。
---@param state table 统计状态
---@param width number 内容宽度
---@param avail_h number 可用高度
---@return table
function Hours:build(state, width, avail_h)
    local t = Theme.current()
    local by_hour, by_wday, total = aggregate(state.calendar.days)
    local function muted(text)
        return Text.line("caption", text, { width = width, color = t.color.muted })
    end
    if total <= 0 then
        return muted(_("暂无本机阅读记录"))
    end
    local gap, xs = Theme.px(t.space.sm), Theme.px(t.space.xs)

    local peak = 1
    for h = 2, 24 do
        if by_hour[h] > by_hour[peak] then peak = h end
    end
    local card_w = math.floor((width - gap) / 2)
    local peak_card = Common.kpiCard(card_w, T(_("%1:00–%2:00"), peak - 1, peak % 24), _("最常阅读时段"))
    local total_card = Common.kpiCard(card_w, Catalog.formatDuration(total), _("本机记录时长"))
    local kpi = HorizontalGroup:new{ align = "center", peak_card, HorizontalSpan:new{ width = gap }, total_card }

    local hint = muted(_("只统计本机记录，不含云端同步来的时长"))
    local hour_title, wday_title = muted(_("按小时")), muted(_("按星期"))
    local used = kpi:getSize().h + gap + hint:getSize().h + gap
        + (hour_title:getSize().h + xs) * 2 + gap
    local chart_h = math.max(Theme.px(48), math.min(Theme.px(180), math.floor((avail_h - used) / 2)))

    local wday_points = {}
    for d = 1, 7 do wday_points[d] = { value = by_wday[d], label = WEEKDAYS[d] } end

    return VerticalGroup:new{
        align = "left",
        kpi,
        VerticalSpan:new{ width = gap },
        hint,
        VerticalSpan:new{ width = gap },
        hour_title,
        VerticalSpan:new{ width = xs },
        Chart.bars({ points = Hours.points(by_hour), width = width, height = chart_h, gap = Theme.px(2) }),
        VerticalSpan:new{ width = gap },
        wday_title,
        VerticalSpan:new{ width = xs },
        Chart.bars({ points = wday_points, width = width, height = chart_h, gap = xs }),
    }
end

return Hours
