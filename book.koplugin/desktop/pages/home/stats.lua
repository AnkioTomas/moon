--[[--
主体：阅读统计三卡。

@module koplugin.book.desktop.pages.home.stats
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Common = require("desktop.detail.common")
local MoonSettings = require("utils.settings")
local Theme = require("ui.themes")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookHomeStats : BookHomeComponent
local M = {
    id = "stats",
    label = _("阅读统计"),
    icon = "insights",
}
setmetatable(M, require("desktop.pages.home.base"))
M.__index = M


local Catalog = require("book.catalog")
local StatsDB = require("book.stats_db")

--- 当前连续阅读天数：今日有读从今天计，否则从昨天计。
---@param daily table[] { ymd, seconds }
---@return number
local function currentStreak(daily)
    local day_set = {}
    for i, row in ipairs(daily or {}) do
        if type(row.ymd) == "string" and (tonumber(row.seconds) or 0) > 0 then
            day_set[row.ymd] = true
        end
    end
    local today = os.date("%Y-%m-%d")
    local cursor = os.time()
    if not day_set[today] then
        cursor = cursor - 86400
    end
    local streak = 0
    while true do
        local ymd = os.date("%Y-%m-%d", cursor)
        if not day_set[ymd] then break end
        streak = streak + 1
        cursor = cursor - 86400
    end
    return streak
end

--- 按展示范围汇总首页三卡指标（混合模式跨已启用源）。
---@param source_id string 当前活跃源；混合时由 Catalog.libraryScope 展开
---@return table
local function summarize(source_id)
    local scope = Catalog.libraryScope(source_id)
    local summary = StatsDB.summaryBySource(scope)
    local daily = StatsDB.dailyBySource(scope)
    local today_ymd = os.date("%Y-%m-%d")
    local today_seconds = 0
    for i, row in ipairs(daily) do
        if row.ymd == today_ymd then
            today_seconds = tonumber(row.seconds) or 0
            break
        end
    end
    return {
        streak = currentStreak(daily),
        total_text = Catalog.formatDuration(summary.total_seconds),
        today_text = Catalog.formatDuration(today_seconds),
    }
end


--- 三张卡的文案（数值、说明）。
---@param source table|nil 所属源
---@return string[][]
local function cards(source)
    local stats = source and summarize(source.id) or {}
    return {
        { T(_("%1天"), stats.streak or 0), _("连续阅读") },
        { stats.total_text or "—", _("总阅读") },
        { stats.today_text or "—", _("今日阅读") },
    }
end

---@return number
local function opacity()
    return MoonSettings.get("desktop.pages.home").home_stats_opacity
end
M.opacity = opacity

--- 编辑态设置：卡片底色不透明度。
---@param desktop BookDesktop
function M:showSettings(desktop)
    require("ui.themes.widgets.spin"):new{
        title = _("卡片底色不透明度（%）"),
        fields = { { value = opacity(), min = 0, max = 100, step = 10 } },
        callback = function(value)
            local home = MoonSettings.get("desktop.pages.home")
            home.home_stats_opacity = value
            MoonSettings.save("desktop.pages.home", home)
            desktop:onEvent("home_refresh")
        end,
    }:show()
end

--- 一张卡的实测高度。
---@return BookHomeHeightSpec
function M:heightRange()
    local _card, h = Common.kpiCard(Theme.px(100), "0", "—")
    return { height = h }
end

--- 从所属源的本地阅读统计构建连续天数、总时长和今日时长卡片。
---@return table
function M:createWidget()
    local w, h = self.opts.width, self.opts.height
    local gap = Theme.px(Theme.current().space.sm)
    local items = cards(self.ctx.source)
    local card_w = math.floor((w - gap * (#items - 1)) / #items)
    local row = HorizontalGroup:new{ align = "center" }
    local key = {}
    for i, item in ipairs(items) do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = (Common.kpiCard(card_w, item[1], item[2], opacity()))
        key[i] = item[1]
    end
    self.key = table.concat(key, "\31")
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, row }
end

--- 统计同步落库后重读；数值全未变时不重建（墨水屏每次 dirty 都是一次真实刷新）。
---@param event string|table 父组件转发的事件名称或事件对象
function M:onEvent(event)
    if event ~= "stats_changed" or not self.slot then return end
    local key = {}
    for i, item in ipairs(cards(self.ctx.source)) do key[i] = item[1] end
    if table.concat(key, "\31") ~= self.key then self:refresh() end
end

return M
