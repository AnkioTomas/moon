--[[--
features.lockscreen.components.chart：柱状图锁屏图元。

@module tests.features.lockscreen.components.chart_spec
--]]

local Assert = require("support.assert")

package.preload["ffi/blitbuffer"] = function()
    local c = function() return {} end
    return {
        COLOR_BLACK = c(), COLOR_WHITE = c(),
        COLOR_GRAY_3 = c(), COLOR_GRAY_4 = c(), COLOR_GRAY_5 = c(),
    }
end

package.loaded["features.lockscreen.components.chart"] = nil
local Chart = require("features.lockscreen.components.chart")

-- 柱状图：空档不画柱，每个点都有标签。
local bars = {}
Chart.appendBars(bars, {
    points = {
        { seconds = 100, label = "01" },
        { seconds = 0, label = "02" },
        { seconds = 200, label = "03" },
    },
    value_key = "seconds",
    x = 10, y = 20, width = 300, height = 80,
})
local vbar_n, label_n, rule_n = 0, 0, 0
for _idx, b in ipairs(bars) do
    if b.kind == "vbar" then vbar_n = vbar_n + 1 end
    if b.kind == "rule" then rule_n = rule_n + 1 end
    if b.text then label_n = label_n + 1 end
end
Assert.eq(vbar_n, 2) -- 空档跳过
Assert.eq(rule_n, 1)
Assert.eq(label_n, 3)

-- 最高柱占满绘图区高度，其余按比例。
local tallest
for _idx, b in ipairs(bars) do
    if b.kind == "vbar" and (not tallest or b.height > tallest.height) then tallest = b end
end
Assert.eq(tallest.height, 80)

-- 统计卡的 7 根柱应铺满绘图区，而不是被默认柱宽上限缩在中间。
local full = {}
local seven = {}
for i = 1, 7 do
    seven[#seven + 1] = { value = i, label = tostring(i) }
end
Chart.appendBars(full, {
    points = seven,
    x = 0, y = 0, width = 400, height = 50,
    bar_cap_ratio = 0.20,
})
local full_rule
for _idx, block in ipairs(full) do
    if block.kind == "rule" then full_rule = block break end
end
Assert.is_true(full_rule.width >= 390)

-- 没有数据点：什么都不画。
Assert.len(Chart.appendBars({}, { points = {}, x = 0, y = 0, width = 100, height = 10 }), 0)
