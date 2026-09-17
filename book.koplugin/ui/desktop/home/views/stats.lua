--[[--
主体：阅读统计三卡。

@module koplugin.book.ui.desktop.home.views.stats
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local Surface = require("ui.components.surface")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookHomeStats : BookHomeComponent
local M = {
    id = "stats",
    label = _("阅读统计"),
    icon = "insights",
}
setmetatable(M, require("ui.desktop.home.views.base"))
M.__index = M


local Catalog = require("book.catalog")
local StatsDB = require("db.stats")

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
---@param source_id string|nil 当前活跃源；混合时由 Catalog.libraryScope 展开
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


local CARD_PAD = 8
local VALUE_LABEL_GAP = 4
local SHADOW = 2

--- 按真实文字控件量一张统计卡高度（含卡内边距，不含阴影）。
---@return number
local function cardHeight()
    local pad = UI.sz(CARD_PAD)
    local value = TextWidget:new{
        text = "0",
        face = UI.face("cfont", 15),
    }
    local label = TextWidget:new{
        text = "—",
        face = UI.face("xx_smallinfofont", 11),
    }
    local height = pad * 2 + value:getSize().h + UI.sz(VALUE_LABEL_GAP) + label:getSize().h
    if value.free then value:free() end
    if label.free then label:free() end
    return height
end

--- 三张统计卡的内容高度（实测文字 + 卡内边距 + 底阴影）。
---@return BookHomeHeightSpec
function M:heightRange()
    return { height = cardHeight() + UI.sz(SHADOW) }
end

--- 造一张「数值 + 说明」统计卡；高度按文本实测撑开。
---@param width number 卡片宽
---@param value string|number 主数值
---@param label string 下方说明文案
---@return table card 卡片 widget
---@return table value_widget 可原地改字的数值控件
local function recordCard(width, value, label)
    local pad = UI.sz(CARD_PAD)
    local inner_w = math.max(1, width - pad * 2)
    local value_widget = TextWidget:new{
        text = tostring(value),
        face = UI.face("cfont", 15),
        max_width = inner_w,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local label_widget = TextWidget:new{
        text = label,
        face = UI.face("xx_smallinfofont", 11),
        max_width = inner_w,
        fgcolor = UI.muted(),
    }
    local height = pad * 2 + value_widget:getSize().h + UI.sz(VALUE_LABEL_GAP) + label_widget:getSize().h
    local card = Surface.build{ child = CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = height - pad * 2 },
        VerticalGroup:new{
            align = "center",
            value_widget,
            VerticalSpan:new{ width = UI.sz(VALUE_LABEL_GAP) },
            label_widget,
        },
    }, options = {
        width = width,
        height = height,
        padding = pad,
        shadow = true,
    }, kind = "card" }
    return card, value_widget
end

--- 从所属源的本地阅读统计构建连续天数、总时长和今日时长卡片。
---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    local w = opts.width
    local total_h = opts.height
    local shadow = UI.sz(SHADOW)
    local inner_w = math.max(1, w - shadow)
    local stats = ctx.source and summarize(ctx.source.id) or {}
    local gap = UI.sz(8)
    local items = {
        { value = T(_("%1天"), stats.streak or 0), label = _("连续阅读") },
        { value = stats.total_text or "—", label = _("总阅读") },
        { value = stats.today_text or "—", label = _("今日阅读") },
    }
    local card_w = math.floor((inner_w - gap * (#items - 1)) / #items)
    local row = HorizontalGroup:new{ align = "center" }
    local values = {}
    for i, item in ipairs(items) do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        local card, value = recordCard(card_w, item.value, item.label)
        values[i] = value
        table.insert(row, card)
    end
    local widget = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        dimen = Geom:new{ w = w, h = total_h },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = total_h },
            row,
        },
    }
    self.values = values
    self.desktop = ctx.desktop
    self.region = Geom:new{ x = 0, y = opts.y or 0, w = w, h = total_h }
    return widget
end

--- 重新查询所属源统计，原地更新三个数值并刷新内容区域。
---@return nil
function M:updateView()
    if not self.values then return end
    local source = self.ctx and self.ctx.source
    local latest = source and summarize(source.id) or {}
    self.values[1]:setText(T(_("%1天"), latest.streak or 0))
    self.values[2]:setText(latest.total_text or "—")
    self.values[3]:setText(latest.today_text or "—")
    self:dirty("content")
end

--- 恢复显示时刷新阅读统计数值。
---@return nil
function M:onResume()
    self:updateView()
end

--- 清除统计文字控件及桌面引用。
---@return nil
function M:onDestroy()
    self.desktop = nil
    self.region = nil
    self.values = nil
end

return M
