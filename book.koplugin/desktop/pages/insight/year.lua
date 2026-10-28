--[[--
统计页「本年」页：年度指标、每月时长图、近一年热力图、今年读完的封面墙。

@module koplugin.book.desktop.pages.insight.year
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Book = require("ui.widgets.book")
local Calc = require("book.insight_calc")
local Catalog = require("book.catalog")
local Heatmap = require("ui.widgets.heatmap")
local Layout = require("desktop.pages.insight.layout")
local Parts = require("desktop.pages.insight.parts")
local Records = require("desktop.pages.insight.records")
local Theme = require("ui.themes")
local Tap = require("ui.themes.widgets.tap")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookInsightYear
local Year = {}

--- 封面墙：按读完先后一格一本，放不下的不画。
---@param desktop table
---@param books table[]
---@param width number
---@param extra number 一行之外还能多放的高度
---@param open_book fun(book: table)
---@return table|nil
local function coverWall(desktop, books, width, extra, open_book)
    local t = Theme.current()
    local gap = Theme.px(t.space.xs)
    local cw = Theme.px(44)
    local ch = math.floor(cw * 1.5)
    local per_row = math.max(1, math.floor((width + gap) / (cw + gap)))
    local rows = 1 + math.floor(extra / (ch + gap))
    if rows < 1 or #books == 0 then return nil end
    local wall = VerticalGroup:new{ align = "left" }
    local shown = math.min(#books, per_row * rows)
    for first = 1, shown, per_row do
        local row = HorizontalGroup:new{ align = "top" }
        for i = first, math.min(first + per_row - 1, shown) do
            local book = books[i]
            local cover = Book.cover(desktop.plugin, desktop.source, book, cw, ch, {
                badge = false, show_parent = desktop,
            })
            if i > first then table.insert(row, HorizontalSpan:new{ width = gap }) end
            table.insert(row, Tap.wrap(cover, function() open_book(book) end))
        end
        if first > 1 then table.insert(wall, VerticalSpan:new{ width = gap }) end
        table.insert(wall, row)
    end
    return wall
end

--- 构建本年页：指标卡、月图、热力图、封面墙，余量由 Layout.stack 分配（封面墙吃剩余高度）。
---@param ctx { desktop: table, state: table, width: number, height: number, open_book: fun(book: table) }
---@return table
function Year:build(ctx)
    local desktop, state, width = ctx.desktop, ctx.state, ctx.width
    local t = Theme.current()
    local xs, sm = Theme.px(t.space.xs), Theme.px(t.space.sm)
    local stats = Records.aggregate(state)
    local year = stats.year
    local done = Calc.finishedIn(
        state.finished or {},
        os.time{ year = year, month = 1, day = 1, hour = 0 },
        os.time{ year = year + 1, month = 1, day = 1, hour = 0 }
    )
    --- 小标题 + 内容。
    local function titled(title, body)
        return VerticalGroup:new{ align = "left",
            Parts.caption(title, width, t.color.accent > 0xFF and t.color.accent or t.color.muted),
            VerticalSpan:new{ width = xs }, body }
    end
    return Layout.stack("year", {
        { id = "kpi", build = function()
            return (Parts.cards({
                { value = Catalog.formatDuration(stats.year_seconds), label = T(_("%1年阅读时长"), year) },
                { value = T(_("%1本"), #done), label = _("今年读完") },
                { value = T(_("%1天"), stats.year_streak), label = _("最长连续") },
            }, width, sm))
        end },
        { id = "monthly", lo = -Theme.px(30), hi = Theme.px(70), build = function(extra)
            return titled(_("每月阅读时长"), Records.monthlyChart(stats, width, Theme.px(88) + extra, xs))
        end },
        { id = "heatmap", build = function()
            return titled(_("近一年阅读热力图"),
                Heatmap:new{ cols = Calc.heatmap(state.calendar.days, os.time()).cols, width = width })
        end },
        { id = "wall", hi = math.huge, build = function(extra)
            local title = Parts.caption(T(_("%1年读完的书"), year), width,
                t.color.accent > 0xFF and t.color.accent or t.color.muted)
            local wall = coverWall(desktop, done, width, extra, ctx.open_book)
            return wall and VerticalGroup:new{ align = "left", title, VerticalSpan:new{ width = xs }, wall }
        end },
    }, width, ctx.height)
end

return Year
