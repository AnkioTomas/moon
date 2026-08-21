--[[--
图表公共组件：柱状图 / 折线图。

两路输出，共用同一套归一化与刻度约定：

  1. `appendBars` / `appendLines` → 锁屏 `render` 图元块
  2. `bars` / `lines` → 桌面 KOReader Widget（按需懒加载）

DESIGN：底对齐、黑填充、灰标签、空档不画柱；折线 1px + 端点方点。

@module koplugin.book.ui.components.chart
--]]

local Blitbuffer = require("ffi/blitbuffer")

local Chart = {}

local DIM = Blitbuffer.COLOR_GRAY_4

---@param opts table
---@return table[] points { value, label }
local function normalizePoints(opts)
    local value_key = opts.value_key or "value"
    local label_key = opts.label_key or "label"
    local out = {}
    if type(opts.points) == "table" then
        for _, row in ipairs(opts.points) do
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
    for _, p in ipairs(points) do
        peak = math.max(peak, p.value or 0)
    end
    return math.max(1, peak)
end

---@param n number
---@param mode string|nil auto/all/ends/none
---@return string
local function resolveLabelMode(n, mode)
    mode = mode or "auto"
    if mode == "auto" then
        return n <= 7 and "all" or "ends"
    end
    return mode
end

--- 向 blocks 追加柱状图（锁屏 render DSL）。
---@param blocks table[]
---@param opts table
---  x,y,width,height 绘图区；points/values；value_key/label_key；
---  label_mode=auto|all|ends|none；label_color；bar_cap_ratio；gap_ratio；min_bar
---@return table[] blocks
function Chart.appendBars(blocks, opts)
    opts = opts or {}
    local points = normalizePoints(opts)
    local n = #points
    local x = opts.x or 0
    local y = opts.y or 0
    local width = opts.width or 0
    local height = opts.height or 0
    local label_color = opts.label_color or DIM
    local label_mode = resolveLabelMode(n, opts.label_mode)
    local gap = math.max(2, math.floor(width * (opts.gap_ratio or 0.012)))
    local bar_cap = math.max(4, math.floor(width * (opts.bar_cap_ratio or 0.08)))
    local min_bar = opts.min_bar or 3
    local peak = maxValue(points)

    local bar_w = n > 0
        and math.max(3, math.min(bar_cap, math.floor((width - gap * (n - 1)) / n)))
        or 3
    local chart_w = n > 0 and (bar_w * n + gap * (n - 1)) or 0
    local chart_x = x + math.max(0, math.floor((width - chart_w) / 2))
    local bar_radius = math.min(3, math.max(1, math.floor(bar_w / 3)))

    if n > 0 then
        blocks[#blocks + 1] = {
            kind = "rule", x = chart_x, y = y + height,
            width = chart_w, height = 1,
        }
    end
    for i, point in ipairs(points) do
        local ratio = (point.value or 0) / peak
        if ratio > 0 then
            local filled = math.max(min_bar, math.floor(height * ratio + 0.5))
            blocks[#blocks + 1] = {
                kind = "vbar",
                x = chart_x + (i - 1) * (bar_w + gap),
                y = y + height - filled,
                width = bar_w,
                height = filled,
                value = 1,
                radius = bar_radius,
            }
        end
    end
    if n > 0 and label_mode ~= "none" then
        local label_y = y + height + 5
        if label_mode == "all" then
            for i, point in ipairs(points) do
                blocks[#blocks + 1] = {
                    text = point.label or "",
                    x = chart_x + (i - 1) * (bar_w + gap),
                    y = label_y,
                    width = bar_w, size = 11, align = "center", box = false, color = label_color,
                }
            end
        else -- ends
            blocks[#blocks + 1] = {
                text = points[1].label or "",
                x = chart_x, y = label_y,
                width = math.floor(chart_w / 2), size = 12, box = false, color = label_color,
            }
            blocks[#blocks + 1] = {
                text = points[n].label or "",
                x = chart_x + math.floor(chart_w / 2), y = label_y,
                width = math.floor(chart_w / 2), size = 12, align = "right", box = false, color = label_color,
            }
        end
    end
    return blocks
end

--- 向 blocks 追加折线图（锁屏 render DSL）。
---@param blocks table[]
---@param opts table 同 appendBars；另：dot_size、stroke
---@return table[] blocks
function Chart.appendLines(blocks, opts)
    opts = opts or {}
    local points = normalizePoints(opts)
    local n = #points
    local x = opts.x or 0
    local y = opts.y or 0
    local width = opts.width or 0
    local height = opts.height or 0
    local label_color = opts.label_color or DIM
    local label_mode = resolveLabelMode(n, opts.label_mode)
    local peak = maxValue(points)
    local color = opts.color or Blitbuffer.COLOR_BLACK
    local dot_size = opts.dot_size or 4
    local stroke = opts.stroke or 1

    if n == 0 then
        return blocks
    end

    -- 点位：左右各留半个步进，底边为 0
    local coords = {}
    for i, point in ipairs(points) do
        local cx = n == 1 and (x + math.floor(width / 2))
            or (x + math.floor((i - 1) * (width - 1) / (n - 1)))
        local ratio = (point.value or 0) / peak
        local cy = y + height - math.floor(height * ratio + 0.5)
        coords[#coords + 1] = { x = cx, y = cy }
    end

    blocks[#blocks + 1] = {
        kind = "rule", x = x, y = y + height,
        width = width, height = 1,
    }
    for i = 1, #coords - 1 do
        blocks[#blocks + 1] = {
            kind = "line",
            x1 = coords[i].x, y1 = coords[i].y,
            x2 = coords[i + 1].x, y2 = coords[i + 1].y,
            color = color,
            stroke = stroke,
        }
    end
    for _, c in ipairs(coords) do
        local half = math.floor(dot_size / 2)
        blocks[#blocks + 1] = {
            kind = "dot",
            x = c.x - half, y = c.y - half,
            size = dot_size,
            color = color,
        }
    end
    if label_mode ~= "none" then
        local label_y = y + height + 5
        local slot_w = n > 1 and math.floor(width / (n - 1)) or width
        if label_mode == "all" then
            for i, point in ipairs(points) do
                local lx = coords[i].x - math.floor(slot_w / 2)
                blocks[#blocks + 1] = {
                    text = point.label or "",
                    x = lx, y = label_y,
                    width = slot_w, size = 11, align = "center", box = false, color = label_color,
                }
            end
        else
            blocks[#blocks + 1] = {
                text = points[1].label or "",
                x = x, y = label_y,
                width = math.floor(width / 2), size = 12, box = false, color = label_color,
            }
            blocks[#blocks + 1] = {
                text = points[n].label or "",
                x = x + math.floor(width / 2), y = label_y,
                width = math.floor(width / 2), size = 12, align = "right", box = false, color = label_color,
            }
        end
    end
    return blocks
end

--- 桌面柱状图 Widget（HorizontalGroup of 竖条）。
---@param opts table width,height,points/values,gap
---@return table widget
function Chart.bars(opts)
    opts = opts or {}
    local UI = require("ui.components.bookui")
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local LineWidget = require("ui/widget/linewidget")
    local TextWidget = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local BottomContainer = require("ui/widget/container/bottomcontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")

    local points = normalizePoints(opts)
    local n = #points
    local width = opts.width or 0
    local height = opts.height or UI.sz(80)
    local gap = opts.gap or UI.sz(4)
    local label_h = opts.show_labels == false and 0 or UI.sz(18)
    local bar_h = math.max(UI.sz(24), height - label_h)
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
            and math.max(UI.sz(2), math.floor(bar_h * seconds / peak + 0.5))
            or UI.line()
        local bar = LineWidget:new{
            background = seconds > 0 and Blitbuffer.COLOR_BLACK or UI.track(),
            dimen = Geom:new{ w = col_w, h = current_h },
        }
        local slot = BottomContainer:new{ dimen = Geom:new{ w = col_w, h = bar_h }, bar }
        if label_h > 0 then
            local month_label = TextWidget:new{
                text = point.label or "",
                face = UI.face("xx_smallinfofont", 10),
                max_width = col_w,
                fgcolor = UI.muted(),
            }
            table.insert(row, VerticalGroup:new{
                align = "center",
                slot,
                VerticalSpan:new{ width = UI.sz(3) },
                CenterContainer:new{ dimen = Geom:new{ w = col_w, h = label_h }, month_label },
            })
        else
            table.insert(row, slot)
        end
    end
    return row
end

--- 桌面折线图 Widget（自定义 paint，Bresenham）。
---@param opts table width,height,points/values
---@return table widget
function Chart.lines(opts)
    opts = opts or {}
    local Widget = require("ui/widget/widget")
    local Geom = require("ui/geometry")
    local points = normalizePoints(opts)
    local width = opts.width or 0
    local height = opts.height or 80
    local peak = maxValue(points)
    local color = opts.color or Blitbuffer.COLOR_BLACK
    local dot_size = opts.dot_size or 4

    local LineChart = Widget:extend{
        width = width,
        height = height,
        points = points,
        peak = peak,
        color = color,
        dot_size = dot_size,
    }

    function LineChart:getSize()
        self.dimen = Geom:new{ w = self.width, h = self.height }
        return self.dimen
    end

    function LineChart:paintTo(bb, x, y)
        local n = #self.points
        if n == 0 then
            return
        end
        local w, h = self.width, self.height
        bb:paintRect(x, y + h - 1, w, 1, Blitbuffer.COLOR_GRAY_5)
        local coords = {}
        for i, point in ipairs(self.points) do
            local cx = n == 1 and (x + math.floor(w / 2))
                or (x + math.floor((i - 1) * (w - 1) / (n - 1)))
            local ratio = (point.value or 0) / self.peak
            local cy = y + h - math.floor(h * ratio + 0.5)
            coords[#coords + 1] = { x = cx, y = cy }
        end
        local function paintSegment(x1, y1, x2, y2)
            local dx = math.abs(x2 - x1)
            local dy = math.abs(y2 - y1)
            local sx = x1 < x2 and 1 or -1
            local sy = y1 < y2 and 1 or -1
            local err = dx - dy
            while true do
                bb:paintRect(x1, y1, 1, 1, self.color)
                if x1 == x2 and y1 == y2 then
                    break
                end
                local e2 = err * 2
                if e2 > -dy then
                    err = err - dy
                    x1 = x1 + sx
                end
                if e2 < dx then
                    err = err + dx
                    y1 = y1 + sy
                end
            end
        end
        for i = 1, #coords - 1 do
            paintSegment(coords[i].x, coords[i].y, coords[i + 1].x, coords[i + 1].y)
        end
        local half = math.floor(self.dot_size / 2)
        for _, c in ipairs(coords) do
            bb:paintRect(c.x - half, c.y - half, self.dot_size, self.dot_size, self.color)
        end
    end

    return LineChart:new{}
end

return Chart
