--[[--
锁屏柱状图：向 render 块追加底对齐竖柱，每根柱下标注。桌面柱图在 ui.widgets.chart。

@module koplugin.book.features.lockscreen.components.chart
--]]

local Blitbuffer = require("ffi/blitbuffer")

---@class BookChart
local Chart = {}

local VALUE_H = 16

--- 向 blocks 追加柱状图（锁屏 render DSL）；值为 0 的位置只留标签不画柱。
--- 每个点占等宽一格、柱在格内居中，基线铺满整个宽度。
---@param blocks table[]
---@param opts { points: table[], value_key: string|nil, x: number, y: number, width: number, height: number, bar_cap_ratio: number|nil, value_label: (fun(value: number): string)|nil, highlight_last: boolean|nil }
---  points 每项含 label 与数值字段（value_key，缺省 value）；
---  value_label 给了就在非零柱顶标数值（占用顶部 VALUE_H）；highlight_last 时只有最后一根是黑柱，其余灰柱
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
    local slot_w = width / n
    local bar_w = math.max(3, math.min(bar_cap, math.floor(slot_w - gap)))
    local bar_radius = math.min(3, math.max(1, math.floor(bar_w / 3)))
    local value_h = opts.value_label and VALUE_H or 0
    local bar_max = math.max(1, height - value_h)

    blocks[#blocks + 1] = {
        kind = "rule", x = x, y = y + height, width = width, height = 1, color = Blitbuffer.COLOR_LIGHT_GRAY,
    }
    for i, point in ipairs(points) do
        local slot_x = x + math.floor((i - 1) * slot_w)
        local bar_x = slot_x + math.floor((slot_w - bar_w) / 2)
        local value = point[value_key]
        local strong = not opts.highlight_last or i == n
        if value > 0 then
            local filled = math.max(3, math.floor(bar_max * value / peak + 0.5))
            blocks[#blocks + 1] = {
                kind = "vbar", x = bar_x, y = y + height - filled,
                width = bar_w, height = filled, value = 1, radius = bar_radius,
                color = strong and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_9,
            }
            if opts.value_label then
                blocks[#blocks + 1] = {
                    text = opts.value_label(value), x = slot_x, y = y + height - filled - VALUE_H,
                    width = math.floor(slot_w), size = 10, align = "center", box = false,
                    color = Blitbuffer.COLOR_GRAY_4,
                }
            end
        end
        blocks[#blocks + 1] = {
            text = point.label, x = slot_x, y = y + height + 5,
            width = math.floor(slot_w), size = 11, align = "center", box = false,
            bold = opts.highlight_last and i == n or nil,
            color = opts.highlight_last and i == n and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_4,
        }
    end
    return blocks
end

return Chart
