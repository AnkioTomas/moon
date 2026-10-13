--[[-- 桌面柱状图：左侧纵坐标按时长标峰值 / 一半 / 0，矮图只标两头。 --]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Chart = require("ui.widgets.chart")

Assert.eq(Chart.axisLabel(0), "0")
Assert.eq(Chart.axisLabel(20), "1分钟", "不足一分钟也标 1 分钟，不显示 0")
Assert.eq(Chart.axisLabel(600), "10分钟")
Assert.eq(Chart.axisLabel(3600), "1小时")
Assert.eq(Chart.axisLabel(5400), "1.5小时")

local function points(peak)
    return { { value = peak, label = "a" }, { value = 0, label = "b" } }
end

local tall = Kit.texts(Chart.bars({ points = points(5400), width = 300, height = 200 }))
for _idx, label in ipairs({ "1.5小时", "45分钟", "0", "a", "b" }) do
    Assert.contains(tall, label)
end

local short = Kit.texts(Chart.bars({ points = points(5400), width = 300, height = 40 }))
Assert.contains(short, "1.5小时")
Assert.contains(short, "0")
for _idx, s in ipairs(short) do
    Assert.is_true(s ~= "45分钟", "柱区放不下三格时不标中间刻度")
end

return true
