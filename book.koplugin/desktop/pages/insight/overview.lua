--[[--
统计页「本月」页：当月指标、月历和当月阅读时段。

@module koplugin.book.desktop.pages.insight.overview
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Calc = require("book.insight_calc")
local Catalog = require("book.catalog")
local Hours = require("desktop.pages.insight.hours")
local Layout = require("desktop.pages.insight.layout")
local Parts = require("desktop.pages.insight.parts")
local Pager = require("ui.themes.widgets.pager")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookInsightOverview
local Overview = {}
local DOW = { _("日"), _("一"), _("二"), _("三"), _("四"), _("五"), _("六") }

--- 年月字符串按月偏移。
---@param ym string YYYY-MM。
---@param delta number 月份偏移量。
---@return string
local function shiftYm(ym, delta)
    local y, m = ym:match("^(%d%d%d%d)%-(%d%d)$")
    y, m = tonumber(y), tonumber(m)
    if not y or not m then return ym end
    m = m + delta
    while m < 1 do m, y = m + 12, y - 1 end
    while m > 12 do m, y = m - 12, y + 1 end
    return string.format("%04d-%02d", y, m)
end

--- 生成年月显示文案。
---@param ym string YYYY-MM。
---@return string
local function ymLabel(ym)
    local y, m = ym:match("^(%d%d%d%d)%-(%d%d)$")
    if not y then return ym end
    return T(_("%1年%2月"), y, tonumber(m))
end

--- 解析日历格对应的真实日期。
---@param y number 当前年份。
---@param m number 当前月份。
---@param day_num number 日历格日号。
---@param days_in_month number 当前月天数。
---@return number, number, number, boolean
local function resolveDay(y, m, day_num, days_in_month)
    if day_num >= 1 and day_num <= days_in_month then
        return y, m, day_num, false
    end
    if day_num < 1 then
        local py, pm = y, m - 1
        if pm < 1 then py, pm = y - 1, 12 end
        local pd = tonumber(os.date("%d", os.time{ year = py, month = pm + 1, day = 0 }))
        return py, pm, pd + day_num, true
    end
    local ny, nm = y, m + 1
    if nm > 12 then ny, nm = y + 1, 1 end
    return ny, nm, day_num - days_in_month, true
end

--- 构建日历单格：有阅读的日子加粗并在下方点一个墨点，选中日描边。
---@param t table 主题令牌
---@param size number 单格边长。
---@param day_num number 显示日号。
---@param has_read boolean 是否有阅读记录。
---@param out_month boolean 是否属于相邻月份。
---@param selected boolean 是否选中。
---@param on_tap fun(ges: table) 点击回调。
---@return table
local function calCell(t, size, day_num, has_read, out_month, selected, on_tap)
    local kids = VerticalGroup:new{
        align = "center",
        Text.line(has_read and "body" or "caption", tostring(day_num), {
            color = out_month and t.color.faint or ((has_read or selected) and t.color.headings or t.color.ink),
            bold = has_read,
        }),
    }
    if has_read and not out_month then
        local dot = Theme.px(t.space.xs)
        kids[#kids + 1] = VerticalSpan:new{ width = Theme.px(2) }
        kids[#kids + 1] = Box:new{ style = { bg = t.color.stat }, width = dot, height = dot, keep_bg = true }
    end
    local style = selected and { border = 2, border_color = t.color.navigation, radius = t.control.radius } or {}
    return Tap.wrap(Box:new{ style = style, width = size, height = size, kids }, on_tap)
end

--- 构建月历网格，并按剩余高度收缩日期格。
---@param desktop table 桌面实例。
---@param state table 统计状态。
---@param width number 内容宽度。
---@param extra number 相对自然高度的增减，摊到每行格子上。
---@return table
local function buildCalendar(desktop, state, width, extra)
    local per_day = (state.calendar and state.calendar.days) or {}
    local ym = state.ym or (state.calendar and state.calendar.initial_ym) or os.date("%Y-%m")
    local selected = state.selected or ""
    local y, m = ym:match("^(%d%d%d%d)%-(%d%d)$")
    y, m = tonumber(y), tonumber(m)
    if not y or not m then
        y, m = tonumber(os.date("%Y")), tonumber(os.date("%m"))
        ym = string.format("%04d-%02d", y, m)
    end
    ---@cast y integer
    ---@cast m integer

    local t = Theme.current()
    local nav = Pager.widget({
        keys = false,
        width = width,
        title = ymLabel(ym),
        on_prev = function()
            state.ym = shiftYm(ym, -1)
            desktop:updateView()
        end,
        on_next = function()
            state.ym = shiftYm(ym, 1)
            desktop:updateView()
        end,
    })
    local dow_h = Text.line("caption", DOW[1]):getSize().h
    local xs = Theme.px(t.space.xs)

    local gap = Theme.px(2)
    local col_w = math.floor((width - gap * 6) / 7)
    local size = math.min(col_w, Theme.px(36))
    local first_wday = tonumber(os.date("%w", os.time{ year = y, month = m, day = 1 })) or 0
    local days_in_month = tonumber(os.date("%d", os.time{ year = y, month = m + 1, day = 0 })) or 30
    local total = math.ceil((first_wday + days_in_month) / 7) * 7
    local rows = math.ceil(total / 7)
    size = math.max(1, math.min(col_w, size + math.floor(extra / rows)))

    local dow_row = HorizontalGroup:new{ align = "center" }
    for i, name in ipairs(DOW) do
        if i > 1 then table.insert(dow_row, HorizontalSpan:new{ width = gap }) end
        table.insert(dow_row, CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = dow_h },
            Text.line("caption", name, { width = col_w, color = t.color.muted }),
        })
    end

    local start_day = 1 - first_wday
    local grid = VerticalGroup:new{ align = "left" }
    local row
    for i = 0, total - 1 do
        if i % 7 == 0 then
            if row then
                table.insert(grid, row)
                table.insert(grid, VerticalSpan:new{ width = gap })
            end
            row = HorizontalGroup:new{ align = "center" }
        elseif row then
            table.insert(row, HorizontalSpan:new{ width = gap })
        end
        local cy, cm, cd, out = resolveDay(y, m, start_day + i, days_in_month)
        local key = string.format("%04d-%02d-%02d", cy, cm, cd)
        local info = per_day[key]
        local seconds = info and info.duration_seconds or 0
        local cell = calCell(t, size, cd, seconds > 0, out, key == selected, function()
            state.selected = key
            if out then state.ym = string.format("%04d-%02d", cy, cm) end
            desktop.insight:switchPage("day")
            desktop:updateView()
        end)
        table.insert(row, CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = size },
            cell,
        })
    end
    if row then table.insert(grid, row) end

    return VerticalGroup:new{
        align = "left",
        nav,
        VerticalSpan:new{ width = xs },
        dow_row,
        VerticalSpan:new{ width = gap },
        grid,
    }
end

--- 构建本月页：指标卡、月历、阅读时段，余量由 Layout.stack 分配（月历格子随之伸缩）。
---@param ctx { desktop: table, state: table, width: number, height: number }
---@return table
function Overview:build(ctx)
    local desktop, state, width = ctx.desktop, ctx.state, ctx.width
    local t = Theme.current()
    local xs, sm = Theme.px(t.space.xs), Theme.px(t.space.sm)
    local days, ym = state.calendar.days, state.ym
    local sum = Calc.sum(days, ym)
    local finished = 0
    for _idx, b in ipairs(state.finished or {}) do
        if os.date("%Y-%m", b.last_time) == ym then finished = finished + 1 end
    end
    return Layout.stack("month", {
        { id = "kpi", build = function()
            return (Parts.cards({
                { value = Catalog.formatDuration(sum.seconds), label = _("本月阅读时长") },
                { value = T(_("%1天"), sum.days), label = _("阅读天数") },
                { value = T(_("%1本"), finished), label = _("读完") },
            }, width, sm))
        end },
        { id = "calendar", lo = -Theme.px(140), hi = Theme.px(120), build = function(extra)
            return VerticalGroup:new{
                align = "left",
                buildCalendar(desktop, state, width, extra),
                VerticalSpan:new{ width = sm },
                Parts.caption(_("点选日期查看当日详情"), width),
            }
        end },
        { id = "hours", lo = -Theme.px(20), hi = Theme.px(60), build = function(extra)
            local chart = Hours.hourChart(days, ym, width, Theme.px(60) + extra)
            if not chart then return nil end
            return VerticalGroup:new{
                align = "left",
                Parts.caption(_("本月阅读时段"), width, t.color.accent > 0xFF and t.color.headings or t.color.muted),
                VerticalSpan:new{ width = xs },
                chart,
            }
        end },
    }, width, ctx.height)
end

return Overview
