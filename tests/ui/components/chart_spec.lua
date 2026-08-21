--[[--
ui.components.chart：柱状图 / 折线图锁屏图元。

@module tests.ui.components.chart_spec
--]]

local Assert = require("support.assert")

package.preload["ffi/blitbuffer"] = function()
    local c = function() return {} end
    return {
        COLOR_BLACK = c(), COLOR_WHITE = c(),
        COLOR_GRAY_3 = c(), COLOR_GRAY_4 = c(), COLOR_GRAY_5 = c(),
    }
end

package.loaded["ui.components.chart"] = nil
local Chart = require("ui.components.chart")

-- 柱状图：空档不画柱，≤7 逐标签
local bars = {}
Chart.appendBars(bars, {
    points = {
        { seconds = 100, label = "01" },
        { seconds = 0, label = "02" },
        { seconds = 200, label = "03" },
    },
    value_key = "seconds",
    x = 10, y = 20, width = 300, height = 80,
    label_mode = "all",
})
local vbar_n, label_n, rule_n = 0, 0, 0
for _, b in ipairs(bars) do
    if b.kind == "vbar" then vbar_n = vbar_n + 1 end
    if b.kind == "rule" then rule_n = rule_n + 1 end
    if b.text then label_n = label_n + 1 end
end
Assert.eq(vbar_n, 2) -- 空档跳过
Assert.eq(rule_n, 1)
Assert.eq(label_n, 3)

-- 长序列：只标首尾
local long = {}
local pts = {}
for i = 1, 12 do
    pts[#pts + 1] = { value = i, label = tostring(i) }
end
Chart.appendBars(long, {
    points = pts,
    x = 0, y = 0, width = 400, height = 50,
    label_mode = "auto",
})
local long_labels = 0
for _, b in ipairs(long) do
    if b.text then long_labels = long_labels + 1 end
end
Assert.eq(long_labels, 2)

-- 折线图：线段 + 点
local lines = {}
Chart.appendLines(lines, {
    values = { 10, 30, 20 },
    labels = { "a", "b", "c" },
    x = 0, y = 0, width = 100, height = 40,
    label_mode = "none",
})
local line_n, dot_n = 0, 0
for _, b in ipairs(lines) do
    if b.kind == "line" then line_n = line_n + 1 end
    if b.kind == "dot" then dot_n = dot_n + 1 end
end
Assert.eq(line_n, 2)
Assert.eq(dot_n, 3)
Assert.eq(lines[2].x1, 0)
Assert.eq(lines[2].x2, 49)

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
    label_mode = "none",
})
local full_rule
for _, block in ipairs(full) do
    if block.kind == "rule" then full_rule = block break end
end
Assert.is_true(full_rule.width >= 390)
