--[[--
统计页「今日」页：选中日期（默认今天）的活动环、阅读时段、每次阅读和书单。

@module koplugin.book.desktop.pages.insight.day
--]]

local Book = require("ui.widgets.book")
local Calc = require("book.insight_calc")
local Chart = require("ui.widgets.chart")
local Hours = require("desktop.pages.insight.hours")
local Ring = require("ui.widgets.ring")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Layout = require("desktop.pages.insight.layout")
local Parts = require("desktop.pages.insight.parts")
local Progress = require("ui.themes.widgets.progress")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local Catalog = require("book.catalog")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookInsightDay
local Day = {}

--- 构建日期标题，可附带该日阅读时长。
---@param ymd string YYYY-MM-DD 日期键。
---@param duration_text string|nil 时长文案。
---@return string
local function dayTitle(ymd, duration_text)
    local _year, month, day = ymd:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not month then return ymd end
    local date = T(_("%1月%2日"), tonumber(month), tonumber(day))
    if duration_text and duration_text ~= "" then
        return T(_("%1 · %2"), date, duration_text)
    end
    return date
end

--- 构建今日页：标题 + 可隐藏的卡片，余量由 Layout.stack 分配。
---@param ctx { desktop: table, state: table, width: number, height: number, open_book: fun(book: table) }
---@return table
function Day:build(ctx)
    local desktop, state, width, open_book = ctx.desktop, ctx.state, ctx.width, ctx.open_book
    local t = Theme.current()
    local selected = state.selected or ""
    local days = state.calendar.days
    local info = selected ~= "" and days[selected] or nil
    local books = info and info.books or {}
    local xs, sm, md = Theme.px(t.space.xs), Theme.px(t.space.sm), Theme.px(t.space.md)
    ---@param text string
    ---@return table
    local function muted(text)
        return Text.line("caption", text, { width = width, color = t.color.muted })
    end
    local title = selected == "" and _("选择日期")
        or dayTitle(selected, info and info.duration_text or nil)

    local rings = Calc.rings(days, os.time(), selected)
    local function ringsBlock(extra)
        local ring_size = Theme.px(88) + extra
        local stats_w = math.max(1, width - ring_size - md)
        local function line(label, r, unit)
            return Text.line("body", T(_("%1 %2 / %3%4"), label, r.value, r.target, unit), { width = stats_w })
        end
        return HorizontalGroup:new{
            align = "center",
            Ring:new{ size = ring_size, rings = {
                { fraction = rings.pages.value / rings.pages.target },
                { fraction = rings.minutes.value / rings.minutes.target },
                { fraction = rings.streak.value / rings.streak.target },
            } },
            HorizontalSpan:new{ width = md },
            VerticalGroup:new{
                align = "left",
                line(_("页数"), rings.pages, ""),
                line(_("分钟"), rings.minutes, ""),
                line(_("连续"), rings.streak, _("天")),
            },
        }
    end

    local function hoursBlock(extra)
        local chart = info and info.hours and Hours.hourChart(days, selected, width, Theme.px(52) + extra)
        if not chart then return nil end
        return VerticalGroup:new{ align = "left", muted(_("阅读时段")), VerticalSpan:new{ width = xs }, chart }
    end

    local titles = {}
    for _idx, b in ipairs(books) do titles[b.stable_id] = b.title end
    local runs = Calc.sessionsOn(state.sessions or {}, selected)
    local function runsBlock()
        if #runs == 0 then return nil end
        local col = VerticalGroup:new{ align = "left" }
        for i = math.max(1, #runs - 2), #runs do
            local s = runs[i]
            col[#col + 1] = Parts.pair(
                T(_("%1–%2 %3"), os.date("%H:%M", s.start), os.date("%H:%M", s.finish), titles[s.stable_id] or ""),
                Catalog.formatDuration(s.seconds), width, Theme.px(90)
            )
        end
        return col
    end

    local cover_w, cover_h = Theme.px(44), Theme.px(66)
    local more_h = muted("0"):getSize().h
    local plugin, api = desktop.plugin, desktop.source
    --- 书单：自然高度放一本，其余按拿到的额外高度往下放，放不下的折成「另有 N 本」。
    local function booksBlock(extra)
        if #books == 0 then return muted(_("这一天没有阅读记录")) end
        local col = VerticalGroup:new{ align = "left" }
        local limit, used, shown = cover_h + extra, 0, 0
        for i, book in ipairs(books) do
            local need = cover_h + (shown > 0 and md or 0)
            local reserve = (i < #books) and (xs + more_h) or 0
            if shown > 0 and used + need + reserve > limit then break end
            if shown > 0 then col[#col + 1] = VerticalSpan:new{ width = md } end
            used = used + need

            local author_text = (book.authors and book.authors ~= "") and book.authors or _("未知作者")
            if book.duration_text and book.duration_text ~= "" then
                author_text = T(_("%1 · %2"), author_text, book.duration_text)
            end
            local cover = Book.cover(plugin, api, book, cover_w, cover_h, {
                badge = false,
                show_parent = desktop,
            })
            local meta_w = math.max(1, width - cover_w - md)
            local meta = VerticalGroup:new{
                align = "left",
                Text.line("body", book.title or book.stable_id or "?", { width = meta_w }),
                VerticalSpan:new{ width = xs },
                Text.line("caption", author_text, { width = meta_w, color = t.color.muted }),
                VerticalSpan:new{ width = sm },
                Progress:new{ width = meta_w, percent = book.percent },
            }
            col[#col + 1] = Tap.wrap(HorizontalGroup:new{
                align = "center",
                cover,
                HorizontalSpan:new{ width = md },
                LeftContainer:new{ dimen = Geom:new{ w = meta_w, h = cover_h }, meta },
            }, function() open_book(book) end)
            shown = shown + 1
        end
        local rest = #books - shown
        if rest > 0 then
            col[#col + 1] = VerticalSpan:new{ width = xs }
            col[#col + 1] = muted(T(_("另有 %1 本未显示"), rest))
        end
        return col
    end

    return Layout.stack("day", {
        { build = function() return Text.line("title", title, { width = width }) end },
        { id = "rings", hi = Theme.px(20), build = ringsBlock },
        { id = "hours", lo = -Theme.px(20), hi = Theme.px(120), build = hoursBlock },
        { id = "runs", build = runsBlock },
        { id = "books", hi = math.huge, build = booksBlock },
    }, width, ctx.height)
end

return Day
