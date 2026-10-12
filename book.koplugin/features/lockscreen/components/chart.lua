--[[--
锁屏柱状图：向 render 块追加底对齐竖柱，每根柱下标注。桌面柱图在 ui.widgets.chart。

@module koplugin.book.features.lockscreen.components.chart
--]]

local Blitbuffer = require("ffi/blitbuffer")

---@class BookChart
local Chart = {}

--- 向 blocks 追加柱状图（锁屏 render DSL）；值为 0 的位置只留标签不画柱。
---@param blocks table[]
---@param opts { points: table[], value_key: string|nil, x: number, y: number, width: number, height: number, bar_cap_ratio: number|nil }
---  points 每项含 label 与数值字段（value_key，缺省 value）
---@return table[] blocks
function Chart.appendBars(blocks, opts)
    local points = opts.points
    local n = #points
    if n == 0 then return blocks end
    local value_key = opts.value_key or "value"
    local x, y, width, height = opts.x, opts.y, opts.width, opts.height
    local gap = math.max(2, math.floor(width * 0.012))
    local bar_cap = math.max(4, math.floor(width * (opts.bar_cap_ratio or 0.08)))
    local peak = 1
    for _idx, point in ipairs(points) do peak = math.max(peak, point[value_key]) end
    local bar_w = math.max(3, math.min(bar_cap, math.floor((width - gap * (n - 1)) / n)))
    local chart_w = bar_w * n + gap * (n - 1)
    local chart_x = x + math.max(0, math.floor((width - chart_w) / 2))
    local bar_radius = math.min(3, math.max(1, math.floor(bar_w / 3)))

    blocks[#blocks + 1] = { kind = "rule", x = chart_x, y = y + height, width = chart_w, height = 1 }
    for i, point in ipairs(points) do
        local bar_x = chart_x + (i - 1) * (bar_w + gap)
        local value = point[value_key]
        if value > 0 then
            local filled = math.max(3, math.floor(height * value / peak + 0.5))
            blocks[#blocks + 1] = {
                kind = "vbar", x = bar_x, y = y + height - filled,
                width = bar_w, height = filled, value = 1, radius = bar_radius,
            }
        end
        blocks[#blocks + 1] = {
            text = point.label, x = bar_x, y = y + height + 5,
            width = bar_w, size = 11, align = "center", box = false, color = Blitbuffer.COLOR_GRAY_4,
        }
    end
    return blocks
end

return Chart
