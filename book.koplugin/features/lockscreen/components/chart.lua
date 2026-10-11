--[[--
锁屏柱状图：向 render 块追加底对齐竖柱。桌面柱图在 ui.widgets.chart。

@module koplugin.book.features.lockscreen.components.chart
--]]

local Blitbuffer = require("ffi/blitbuffer")

---@class BookChart
local Chart = {}

local DIM = Blitbuffer.COLOR_GRAY_4

---@param opts table
---@return table[] points { value, label }
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

return Chart
