--[[--
统计页「趋势」页：近 90 天对比过去一年的六项指标，以及近 7 天对比前 7 天。

近 90 天与过去一年都截止到昨天；某项高于或接近（3% 内）一年均值算「保持」，低于算「回落」。
历史不足 120 天、或缺该项数据时标「数据不足」，不编造。

@module koplugin.book.desktop.pages.insight.trends
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Calc = require("book.insight_calc")
local Catalog = require("book.catalog")
local Chart = require("ui.widgets.chart")
local Layout = require("desktop.pages.insight.layout")
local Parts = require("desktop.pages.insight.parts")
local Theme = require("ui.themes")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookInsightTrends
local Trends = {}

local function fmt(n) return (string.format("%.1f", n):gsub("%.0$", "")) end

local METRICS = {
    minutes = { _("每天阅读"), function(v) return T(_("%1分钟"), fmt(v)) end },
    pages = { _("每天页数"), function(v) return T(_("%1页"), fmt(v)) end },
    days = { _("每周阅读天数"), function(v) return T(_("%1天"), fmt(v)) end },
    session = { _("单次阅读"), function(v) return T(_("%1分钟"), fmt(v)) end },
    speed = { _("阅读速度"), function(v) return T(_("%1页/小时"), fmt(v)) end },
    books = { _("每月读完"), function(v) return T(_("%1本"), fmt(v)) end },
}

local STATUS = { up = _("保持"), flat = _("保持"), down = _("回落"), nodata = _("数据不足") }

--- 构建趋势页：90 天对比表与本周对比图；图表吃余量。
---@param ctx { state: table, width: number, height: number }
---@return table
function Trends:build(ctx)
    local state, width = ctx.state, ctx.width
    local t = Theme.current()
    local xs = Theme.px(t.space.xs)
    local now = os.time()
    local trend = Calc.trends(state.calendar.days, state.sessions or {}, state.finished or {}, now)

    local function compareBlock()
        local col = VerticalGroup:new{
            align = "left",
            Parts.caption(_("近 90 天 对比 过去一年"), width),
            VerticalSpan:new{ width = xs },
        }
        if not trend.enough then
            col[#col + 1] = Text.box("body", _("阅读不满四个月，攒够数据再来看趋势"), width, { color = t.color.muted })
            return col
        end
        local w3, w4 = math.floor(width * 0.34), math.floor(width * 0.2)
        local w2 = math.floor((width - w3 - w4) / 2)
        for _idx, m in ipairs(trend.metrics) do
            local spec = METRICS[m.key]
            local recent = m.recent and spec[2](m.recent) or "—"
            local base = m.base and spec[2](m.base) or "—"
            col[#col + 1] = HorizontalGroup:new{
                align = "center",
                Parts.cell(Text.line("body", spec[1], { width = w3 }), w3),
                Parts.cell(Text.line("caption", recent, { width = w2, color = t.color.muted }), w2, true),
                Parts.cell(Text.line("caption", base, { width = w2, color = t.color.muted }), w2, true),
                Parts.cell(Text.line("body", STATUS[m.status], { width = w4, bold = m.status == "down" }), w4, true),
            }
        end
        return col
    end

    local wk = Calc.weekCompare(state.calendar.days, now)
    local summary = T(_("近 7 天 %1，前 7 天 %2"),
        Catalog.formatDuration(wk.seconds), Catalog.formatDuration(wk.prev_seconds))
    if wk.change then
        summary = summary .. T(_("（%1%2%）"), wk.change >= 0 and "+" or "-", math.floor(math.abs(wk.change) * 100 + 0.5))
    end
    local points = {}
    for i, bar in ipairs(wk.bars) do
        points[i] = { value = bar.seconds, label = tostring(tonumber(bar.ymd:sub(9, 10))) }
    end
    local function weekBlock(extra)
        return VerticalGroup:new{
            align = "left",
            Parts.caption(summary, width),
            VerticalSpan:new{ width = xs },
            Chart.bars({ points = points, width = width, gap = Theme.px(4), height = Theme.px(64) + extra }),
        }
    end

    return Layout.stack("trends", {
        { id = "compare", build = compareBlock },
        { id = "week", lo = -Theme.px(20), hi = Theme.px(200), build = weekBlock },
    }, width, ctx.height)
end

return Trends
