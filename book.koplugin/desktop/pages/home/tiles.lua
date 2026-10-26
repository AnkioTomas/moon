--[[--
主体：阅读小卡四宫格（连续阅读、本周、本月挑战、今年读完），半宽两列。

数据全部来自本地阅读统计，计算复用统计页的 book.insight_calc；点按进统计页。

@module koplugin.book.desktop.pages.home.tiles
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Calc = require("book.insight_calc")
local Catalog = require("book.catalog")
local MoonSettings = require("utils.settings")
local StatsDB = require("book.stats_db")
local Stats = require("desktop.pages.home.stats")
local Ring = require("ui.widgets.ring")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookHomeTiles : BookHomeComponent
---@field key string|nil 当前显示的数值签名
local M = {
    id = "tiles",
    label = _("阅读小卡"),
    icon = "dashboard",
}
setmetatable(M, require("desktop.pages.home.base"))
M.__index = M
M.showSettings = Stats.showSettings

local DAY = 86400
local VISUAL_H = 28

--- 最近一年的日表与今年读完的书，转成 insight_calc 吃的形状。
---@param source table|nil 所属源
---@return table data { streak, dots, bars, week_seconds, challenge, done, projected }
local function collect(source)
    local now = os.time()
    local days, finished = {}, {}
    if source then
        local scope = Catalog.libraryScope(source.id)
        for _idx, row in ipairs(StatsDB.dailyBySource(scope, now - 366 * DAY, now + DAY)) do
            days[row.ymd] = { duration_seconds = row.seconds, pages = row.pages or 0 }
        end
        finished = StatsDB.progressBooks(scope, true)
    end
    local goals = MoonSettings.get("desktop.pages.insight")
    local week = Calc.weekCompare(days, now)
    local fc = Calc.forecast(days, {}, finished, now)
    return {
        streak = Calc.streak(days, os.date("%Y-%m-%d", now) --[[@as string]]),
        bars = week.bars,
        week_seconds = week.seconds,
        challenge = Calc.challenge(days, now, goals.month_goal_hours * 3600),
        done = fc.done,
        projected = fc.projected,
        year_goal = goals.year_goal_books,
    }
end

--- 显示签名：只含会改变画面的数值。
---@param data table
---@return string
local function keyOf(data)
    local out = { data.streak, data.week_seconds, data.done, data.projected, data.year_goal,
        data.challenge and math.floor(data.challenge.ratio * 100) or -1 }
    for _idx, bar in ipairs(data.bars) do out[#out + 1] = math.min(4, math.ceil(bar.seconds / 900)) end
    return table.concat(out, "\31")
end

--- 近 7 天圆点，读过的实心。
---@param data table
---@return table
local function dots(data)
    local t = Theme.current()
    local d, gap = Theme.px(10), Theme.px(6)
    local row = HorizontalGroup:new{ align = "center" }
    for i, bar in ipairs(data.bars) do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        local bg = bar.seconds > 0 and t.color.ink or t.progress.track
        row[#row + 1] = Box:new{ style = { bg = bg, radius = 999 }, width = d, height = d }
    end
    return row
end

--- 近 7 天小柱，峰值贴满视觉区高度。
---@param data table
---@return table
local function bars(data)
    local t = Theme.current()
    local h, gap, bw = Theme.px(VISUAL_H), Theme.px(4), Theme.px(10)
    local peak = 1
    for _idx, bar in ipairs(data.bars) do peak = math.max(peak, bar.seconds) end
    local row = HorizontalGroup:new{ align = "bottom" }
    for i, bar in ipairs(data.bars) do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        local bh = bar.seconds > 0 and math.max(Theme.px(2), math.floor(h * bar.seconds / peak)) or Theme.px(1)
        local bg = bar.seconds > 0 and t.color.ink or t.progress.track
        row[#row + 1] = Box:new{ style = { bg = bg }, width = bw, height = bh }
    end
    return row
end

--- 一张卡：小标题、数值、一行视觉件。
---@param w number
---@param caption string
---@param value string
---@param visual table
---@return table card
local function tile(w, caption, value, visual)
    local t = Theme.current()
    local pad = Theme.px(t.space.sm)
    local inner = math.max(1, w - pad * 2)
    return Box:new{
        style = t.card,
        bg_alpha = Stats.opacity(),
        width = w,
        padding = pad,
        VerticalGroup:new{
            align = "left",
            Text.line("caption", caption, { width = inner, color = t.color.muted }),
            VerticalSpan:new{ width = Theme.px(t.space.xs) },
            Text.line("title", value, { width = inner }),
            VerticalSpan:new{ width = Theme.px(t.space.xs) },
            CenterContainer:new{ dimen = Geom:new{ w = inner, h = Theme.px(VISUAL_H) }, visual },
        },
    }
end

---@param w number 每张卡宽
---@param data table
---@return table[] cards
local function tiles(w, data)
    local ch = data.challenge
    local ring_size = Theme.px(VISUAL_H)
    local challenge_visual = HorizontalGroup:new{
        align = "center",
        Ring:new{ size = ring_size, rings = { { fraction = ch and ch.ratio or 0 } } },
        HorizontalSpan:new{ width = Theme.px(Theme.current().space.sm) },
        Text.line("caption", ch and (ch.on_pace and _("进度正常") or _("稍落后")) or "",
            { color = Theme.current().color.muted }),
    }
    return {
        tile(w, _("连续阅读"), T(_("%1天"), data.streak), dots(data)),
        tile(w, _("近 7 天"), Catalog.formatDuration(data.week_seconds), bars(data)),
        tile(w, T(_("%1月挑战"), tonumber(os.date("%m"))),
            ch and (math.floor(ch.ratio * 100) .. "%") or "—", challenge_visual),
        tile(w, _("今年读完"), data.year_goal > 0 and T(_("%1 / %2本"), data.done, data.year_goal)
                or T(_("%1本"), data.done),
            Text.line("caption", T(_("按此节奏全年约 %1 本"), data.projected),
                { color = Theme.current().color.muted })),
    }
end

---@return table[] cards
---@param w number
local function sample(w)
    return tiles(w, { streak = 0, bars = { { seconds = 0 } }, week_seconds = 0, done = 0, projected = 0, year_goal = 0 })
end

--- 两行卡的自然高度加行距。
---@return BookHomeHeightSpec
function M:heightRange()
    local card_h = sample(Theme.px(200))[1]:getSize().h
    return { height = card_h * 2 + Theme.px(Theme.current().space.sm) }
end

---@return table
function M:createWidget()
    local w, h = self.opts.width, self.opts.height
    local gap = Theme.px(Theme.current().space.sm)
    local card_w = math.floor((w - gap) / 2)
    local data = collect(self.ctx.source)
    self.key = keyOf(data)
    local cards = tiles(card_w, data)
    local function row(a, b)
        return HorizontalGroup:new{ align = "top", a, HorizontalSpan:new{ width = gap }, b }
    end
    local body = VerticalGroup:new{
        align = "left",
        row(cards[1], cards[2]),
        VerticalSpan:new{ width = gap },
        row(cards[3], cards[4]),
    }
    local desktop = self.ctx.desktop
    return Tap.wrap(CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, body },
        desktop and function() desktop:switchTab("insight") end or nil)
end

--- 统计落库后重读；数值全未变时不重建（墨水屏每次 dirty 都是一次真实刷新）。
---@param event string|table 父组件转发的事件名称或事件对象
function M:onEvent(event)
    if event ~= "stats_changed" or not self.slot then return end
    if keyOf(collect(self.ctx.source)) ~= self.key then self:refresh() end
end

--- 回到桌面时已跨天：连续天数、近 7 天窗口都挪了，重画。
function M:onActivate()
    if self.slot and keyOf(collect(self.ctx.source)) ~= self.key then self:refresh() end
end

return M
