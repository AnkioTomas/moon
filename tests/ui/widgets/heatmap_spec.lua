--[[-- 热力图铺满给定宽度：53 周除不尽的像素摊进列距，右缘贴齐。 --]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Heatmap = require("ui.widgets.heatmap")

local cols = {}
for c = 1, 53 do
    cols[c] = {}
    for r = 1, 7 do cols[c][r] = { level = (c + r) % 5 } end
end
local hm = Heatmap:new{ width = 500, cols = cols }
Assert.eq(hm:getSize().w, 500, "网格宽等于给定宽度")

local xs = {}
local canvas = Kit.canvas()
canvas.paintRect = function(_self, x, _y, w, _h)
    xs[#xs + 1] = { x, w }
end
hm:paintTo(canvas, 10, 0)
Assert.eq(xs[1][1], 10, "第一列从左缘起")
local last = xs[#xs]
Assert.eq(last[1] + last[2], 510, "最后一列右缘贴齐宽度")

return true
