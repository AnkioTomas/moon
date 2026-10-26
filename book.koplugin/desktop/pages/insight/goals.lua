--[[--
统计页「进度」页：本月挑战、完成预测、连续记录与里程碑。

本月挑战的目标默认由近 90 天日均 ×1.1 自动推算，点挑战块可自己设本月时长与今年读完本数（首页小卡同用）；
完成预测按每本书自己的速度和近 30 天日均。

@module koplugin.book.desktop.pages.insight.goals
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Calc = require("book.insight_calc")
local Catalog = require("book.catalog")
local Layout = require("desktop.pages.insight.layout")
local MoonSettings = require("utils.settings")
local Parts = require("desktop.pages.insight.parts")
local Records = require("desktop.pages.insight.records")
local Ring = require("ui.widgets.ring")
local Theme = require("ui.themes")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookInsightGoals
local Goals = {}

--- 构建进度页：本月挑战、预计读完、连续记录；挑战环吃余量。
---@param ctx { desktop: table, state: table, width: number, height: number, open_book: fun(book: table) }
---@return table
function Goals:build(ctx)
    local state, width, open_book = ctx.state, ctx.width, ctx.open_book
    local t = Theme.current()
    local xs, md = Theme.px(t.space.xs), Theme.px(t.space.md)
    local now = os.time()
    local days = state.calendar.days
    local goals = MoonSettings.get("desktop.pages.insight")
    local ch = Calc.challenge(days, now, goals.month_goal_hours * 3600)
    local fc = Calc.forecast(days, state.reading or {}, state.finished or {}, now)

    local function editGoals()
        require("ui.themes.widgets.spin"):new{
            title = _("阅读目标"),
            fields = {
                { label = _("本月（小时）"), value = goals.month_goal_hours, min = 0, max = 300,
                    format = function(v) return v == 0 and _("自动") or tostring(v) end },
                { label = _("今年读完（本）"), value = goals.year_goal_books, min = 0, max = 500,
                    format = function(v) return v == 0 and _("不设") or tostring(v) end },
            },
            callback = function(hours, books)
                goals.month_goal_hours, goals.year_goal_books = hours, books
                MoonSettings.save("desktop.pages.insight", goals)
                ctx.desktop:updateView()
            end,
        }:show()
    end

    local function challengeBlock(extra)
        local title = Parts.caption(T(_("%1月挑战"), tonumber(os.date("%m", now))), width,
            t.color.accent > 0xFF and t.color.headings or t.color.muted)
        if not ch then
            return Tap.wrap(VerticalGroup:new{
                align = "left",
                title,
                VerticalSpan:new{ width = xs },
                Parts.caption(_("点按设置阅读目标"), width),
            }, editGoals)
        end
        local size = Theme.px(72) + extra
        local text_w = math.max(1, width - size - md)
        return Tap.wrap(VerticalGroup:new{
            align = "left",
            title,
            VerticalSpan:new{ width = xs },
            HorizontalGroup:new{
                align = "center",
                Ring:new{ size = size, rings = { { fraction = ch.ratio } } },
                HorizontalSpan:new{ width = md },
                VerticalGroup:new{
                    align = "left",
                    Text.line("body", T(_("%1 / %2"), Catalog.formatDuration(ch.done), Catalog.formatDuration(ch.target)),
                        { width = text_w }),
                    Text.line("caption", ch.done >= ch.target and _("已完成")
                        or T(_("每天还需 %1 · %2"), Catalog.formatDuration(ch.per_day),
                            ch.on_pace and _("节奏正常") or _("稍有落后")),
                        { width = text_w, color = t.color.muted }),
                },
            },
        }, editGoals)
    end

    local function forecastBlock()
        if #fc.books == 0 and fc.done == 0 and goals.year_goal_books == 0 then return nil end
        local col = VerticalGroup:new{ align = "left" }
        if #fc.books > 0 then
            col[#col + 1] = Parts.caption(_("预计读完"), width,
                t.color.accent > 0xFF and t.color.headings or t.color.muted)
            col[#col + 1] = VerticalSpan:new{ width = xs }
            for i = 1, math.min(3, #fc.books) do
                local item = fc.books[i]
                local date = T("%1/%2", tonumber(item.date:sub(6, 7)), tonumber(item.date:sub(9, 10)))
                col[#col + 1] = Tap.wrap(Parts.pair(
                    item.book.title or item.book.stable_id,
                    T(_("%1天后 · %2"), item.days_left, date), width, Theme.px(130)
                ), function() open_book(item.book) end)
            end
        end
        if goals.year_goal_books > 0 then
            col[#col + 1] = Parts.caption(
                T(_("今年读完 %1 / %2 本，照此节奏全年约 %3 本"), fc.done, goals.year_goal_books, fc.projected), width)
        elseif fc.done > 0 then
            col[#col + 1] = Parts.caption(T(_("今年已读完 %1 本，照此节奏全年约 %2 本"), fc.done, fc.projected), width)
        end
        return col
    end

    return Layout.stack("goals", {
        { id = "challenge", hi = Theme.px(60), build = challengeBlock },
        { id = "forecast", build = forecastBlock },
        { id = "records", build = function() return Records:build(state, width) end },
    }, width, ctx.height)
end

return Goals
