--[[--
主体：阅读热力图。列为周（最右是本周），行为周一到周日，格子深浅按当天阅读时长分 5 档；点按进统计页。

周数按宽度能放下多少算多少；时长口径同统计页日历（StatsDB.dailyBySource，混合模式跨已启用源）。

@module koplugin.book.desktop.pages.home.heatmap
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Catalog = require("book.catalog")
local StatsDB = require("book.stats_db")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookHomeHeatmap : BookHomeComponent
---@field key string|nil 当前显示的档位签名
---@field weeks integer|nil 当前显示的周数
---@field day string|nil 画的时候是哪天
---@field collected { weeks: integer, levels: (integer|false)[][], total: number }|nil onEvent 已读到的数据，下次重建直接用
local M = {
    id = "heatmap",
    label = _("阅读热力图"),
    icon = "calendar_view_month",
}
setmetatable(M, require("desktop.pages.home.base"))
M.__index = M

local CELL, MAX_CELL, GAP = 14, 24, 2
local MAX_WEEKS = 53

--- 最近 weeks 周的档位：levels[周][1..7] 为 0..4，今天之后为 false。
---@param source table|nil 所属源
---@param weeks integer
---@return (integer|false)[][] levels
---@return number total 区间内总秒数
local function collect(source, weeks)
    local now = os.date("*t")
    -- 取正午推日期：跨夏令时差一小时也落不到隔壁一天
    local today = os.time{ year = now.year, month = now.month, day = now.day, hour = 12 }
    local start = today - ((now.wday + 5) % 7 + (weeks - 1) * 7) * 86400
    local by_day = {}
    if source then
        -- 只聚合画得到的那几周，不扫全部历史（每次统计落库都会重算）
        local rows = StatsDB.dailyBySource(Catalog.libraryScope(source.id), start - 43200, today + 43200)
        for _idx, row in ipairs(rows) do
            by_day[row.ymd] = row.seconds
        end
    end
    local seconds, peak, total = {}, 0, 0
    for i = 1, weeks * 7 do
        local ts = start + (i - 1) * 86400
        local s = ts <= today and (by_day[os.date("%Y-%m-%d", ts)] or 0) or false
        seconds[i] = s
        if s then
            peak = math.max(peak, s)
            total = total + s
        end
    end
    local levels = {}
    for w = 1, weeks do
        levels[w] = {}
        for d = 1, 7 do
            local s = seconds[(w - 1) * 7 + d]
            levels[w][d] = s and (s > 0 and math.ceil(s / peak * 4) or 0)
        end
    end
    return levels, total
end

--- 显示签名：档位相同但总时长变了，标题仍要重画。
---@param levels (integer|false)[][]
---@param total number
---@return string
local function keyOf(levels, total)
    local out = { tostring(total) }
    for _w, column in ipairs(levels) do
        for d = 1, 7 do out[#out + 1] = tostring(column[d]) end
    end
    return table.concat(out, "\31")
end

--- 7 行格子的自然高度（加标题行）。
---@return BookHomeHeightSpec
function M:heightRange()
    local t = Theme.current()
    local caption_h = Text.line("caption", "0"):getSize().h
    return { height = caption_h + Theme.px(t.space.xs) + Theme.px(CELL) * 7 + Theme.px(GAP) * 6 }
end

---@return table
function M:createWidget()
    local t = Theme.current()
    local w, h = self.opts.width, self.opts.height
    local xs, gap = Theme.px(t.space.xs), Theme.px(GAP)
    local caption_h = Text.line("caption", "0"):getSize().h
    local cell = math.max(1, math.min(Theme.px(MAX_CELL), math.floor((h - caption_h - xs - gap * 6) / 7)))
    local weeks = math.max(1, math.min(MAX_WEEKS, math.floor((w + gap) / (cell + gap))))
    local fresh = self.collected
    self.collected = nil
    local levels, total
    if fresh and fresh.weeks == weeks then
        levels, total = fresh.levels, fresh.total
    else
        levels, total = collect(self.ctx.source, weeks)
    end
    self.weeks, self.key, self.day = weeks, keyOf(levels, total), os.date("%Y-%m-%d") --[[@as string]]

    local track, ink = t.progress.track, t.color.accent
    local shades = {}
    for level = 0, 4 do shades[level] = Theme.mix(track, ink, level / 4) end
    local grid = HorizontalGroup:new{ align = "top" }
    for wi, column in ipairs(levels) do
        if wi > 1 then grid[#grid + 1] = HorizontalSpan:new{ width = gap } end
        local col = VerticalGroup:new{ align = "left" }
        for d = 1, 7 do
            if d > 1 then col[#col + 1] = VerticalSpan:new{ width = gap } end
            local level = column[d]
            local bg = level and shades[level] or nil
            col[#col + 1] = Box:new{ style = { bg = bg }, width = cell, height = cell, keep_bg = true }
        end
        grid[#grid + 1] = col
    end
    local body = VerticalGroup:new{
        align = "left",
        Text.line("caption", T(_("最近 %1 周 · %2"), weeks, Catalog.formatDuration(total)),
            { width = grid:getSize().w, color = t.color.muted }),
        VerticalSpan:new{ width = xs },
        grid,
    }
    local desktop = self.ctx.desktop
    return Tap.wrap(CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, body },
        desktop and function() desktop:switchTab("insight") end or nil)
end

--- 回到桌面时已经跨天：「今天」挪了一格，重画。
function M:onActivate()
    if self.slot and self.day ~= os.date("%Y-%m-%d") then self:refresh() end
end

--- 统计落库后重读；档位全未变时不重建（墨水屏每次 dirty 都是一次真实刷新），变了就把这次读到的交给重建。
---@param event string|table 父组件转发的事件名称或事件对象
function M:onEvent(event)
    if event ~= "stats_changed" or not self.slot then return end
    local levels, total = collect(self.ctx.source, self.weeks)
    if keyOf(levels, total) == self.key then return end
    self.collected = { weeks = self.weeks, levels = levels, total = total }
    self:refresh()
end

return M
