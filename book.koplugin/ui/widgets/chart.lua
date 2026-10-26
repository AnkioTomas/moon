--[[--
桌面柱状图。锁屏图元在 features.lockscreen.components.chart。

@module koplugin.book.ui.widgets.chart
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Text = require("ui.themes.widgets.text")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local _ = require("gettext")
local T = require("ffi/util").template

local Chart = {}

--- 纵坐标刻度文案；值是秒。满 1 小时按小时保留一位小数，否则按分钟。
---@param seconds number
---@return string
function Chart.axisLabel(seconds)
    if seconds <= 0 then return "0" end
    if seconds >= 3600 then
        return T(_("%1小时"), string.format("%g", math.floor(seconds / 360 + 0.5) / 10))
    end
    return T(_("%1分钟"), math.max(1, math.floor(seconds / 60 + 0.5)))
end

local function normalizePoints(opts)
    local value_key = opts.value_key or "value"
    local label_key = opts.label_key or "label"
    local out = {}
    if type(opts.points) == "table" then
        for _idx, row in ipairs(opts.points) do
            if type(row) == "table" then
                out[#out + 1] = {
                    value = tonumber(row[value_key] or row.value or row.seconds) or 0,
                    label = row[label_key] or row.label or row.key or "",
                }
            else
                out[#out + 1] = { value = tonumber(row) or 0, label = "" }
            end
        end
        return out
    end
    local values = opts.values or {}
    local labels = opts.labels or {}
    for i, v in ipairs(values) do
        out[#out + 1] = {
            value = tonumber(v) or 0,
            label = labels[i] or "",
        }
    end
    return out
end

---@param points table[]
---@return number
local function maxValue(points)
    local peak = 0
    for _idx, p in ipairs(points) do
        peak = math.max(peak, p.value or 0)
    end
    return math.max(1, peak)
end

--- 纵坐标：峰值贴柱区顶、0 贴柱区底，放得下三格时中间再标一半；刻度右对齐，右侧一条竖线。
---@param peak number
---@param bar_h number 柱区高度
---@return table widget
---@return number w
local function axis(peak, bar_h)
    local Geom = require("ui/geometry")
    local LineWidget = require("ui/widget/linewidget")
    local OverlapGroup = require("ui/widget/overlapgroup")
    local t = Theme.current()
    local function label(value)
        return Text.line("caption", Chart.axisLabel(value), { color = t.color.muted })
    end
    local top, bottom = label(peak), label(0)
    local text_h = top:getSize().h
    local ticks = { { top, 0 }, { bottom, bar_h - text_h } }
    if bar_h >= text_h * 3 then
        ticks[3] = { label(peak / 2), math.floor((bar_h - text_h) / 2) }
    end
    local label_w = 0
    for _idx, tick in ipairs(ticks) do label_w = math.max(label_w, tick[1]:getSize().w) end
    local line_w = math.max(1, Theme.px(t.row.divider))
    local w = label_w + Theme.px(t.space.xs) + line_w
    local group = OverlapGroup:new{ dimen = Geom:new{ w = w, h = bar_h } }
    for _idx, tick in ipairs(ticks) do
        local widget = tick[1]
        widget.overlap_offset = { label_w - widget:getSize().w, math.max(0, tick[2]) }
        group[#group + 1] = widget
    end
    local line = LineWidget:new{
        background = Blitbuffer.Color8(t.color.rule),
        dimen = Geom:new{ w = line_w, h = bar_h },
    }
    line.overlap_offset = { w - line_w, 0 }
    group[#group + 1] = line
    return group, w
end

--- 桌面柱状图 Widget（左侧纵坐标 + HorizontalGroup of 竖条）；值是秒。
---@param opts table width,height,points/values,gap
---@return table widget
function Chart.bars(opts)
    opts = opts or {}
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local BottomContainer = require("ui/widget/container/bottomcontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")

    local points = normalizePoints(opts)
    local n = #points
    local t = Theme.current()
    local height = opts.height or Theme.px(80)
    local gap = opts.gap or Theme.px(t.space.xs)
    local label_h = opts.show_labels == false and 0 or Theme.px(18)
    local bar_h = math.max(Theme.px(24), height - label_h)
    local peak = maxValue(points)
    local axis_widget, axis_w = axis(peak, bar_h)
    local axis_gap = Theme.px(t.space.xs)
    local width = math.max(1, (opts.width or 0) - axis_w - axis_gap)
    local col_w = n > 0
        and math.max(1, math.floor((width - gap * math.max(0, n - 1)) / n))
        or width

    local row = HorizontalGroup:new{ align = "center" }
    for i, point in ipairs(points) do
        if i > 1 then
            table.insert(row, HorizontalSpan:new{ width = gap })
        end
        local seconds = point.value or 0
        local current_h = peak > 0 and seconds > 0
            and math.max(Theme.px(2), math.floor(bar_h * seconds / peak + 0.5))
            or math.max(1, Theme.px(t.row.divider))
        local bar = Box:new{
            style = { bg = seconds > 0 and t.progress.fill or t.progress.track }, keep_bg = true,
            width = col_w, height = current_h,
        }
        local slot = BottomContainer:new{ dimen = Geom:new{ w = col_w, h = bar_h }, bar }
        if label_h > 0 then
            local month_label = Text.line("caption", point.label or "", {
                width = col_w, color = t.color.muted,
            })
            table.insert(row, VerticalGroup:new{
                align = "center",
                slot,
                VerticalSpan:new{ width = Theme.px(3) },
                CenterContainer:new{ dimen = Geom:new{ w = col_w, h = label_h }, month_label },
            })
        else
            table.insert(row, slot)
        end
    end
    return HorizontalGroup:new{
        align = "top",
        axis_widget,
        HorizontalSpan:new{ width = axis_gap },
        row,
    }
end

return Chart
