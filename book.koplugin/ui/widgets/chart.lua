--[[--
桌面柱状图。锁屏图元在 features.lockscreen.components.chart。

@module koplugin.book.ui.widgets.chart
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Text = require("ui.themes.widgets.text")
local Theme = require("ui.themes")

local Chart = {}

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

--- 桌面柱状图 Widget（HorizontalGroup of 竖条）。
---@param opts table width,height,points/values,gap
---@return table widget
function Chart.bars(opts)
    opts = opts or {}
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local LineWidget = require("ui/widget/linewidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local BottomContainer = require("ui/widget/container/bottomcontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")

    local points = normalizePoints(opts)
    local n = #points
    local width = opts.width or 0
    local t = Theme.current()
    local height = opts.height or Theme.px(80)
    local gap = opts.gap or Theme.px(t.space.xs)
    local label_h = opts.show_labels == false and 0 or Theme.px(18)
    local bar_h = math.max(Theme.px(24), height - label_h)
    local peak = maxValue(points)
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
        local bar = LineWidget:new{
            background = Blitbuffer.Color8(seconds > 0 and t.color.ink or t.progress.track),
            dimen = Geom:new{ w = col_w, h = current_h },
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
    return row
end

return Chart
