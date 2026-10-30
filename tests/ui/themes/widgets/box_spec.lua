--[[--
ui.themes.widgets.box / progress：自绘表面与进度条按主题令牌出图。

@module tests.ui.themes.widgets.box_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("bold")

local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Progress = require("ui.themes.widgets.progress")

-- bold 卡片：阴影计入尺寸但不挤占宽高；先阴影、再底、再边框；子件在框内居中。
local bold = Theme.current()
local painted
local child = {
    getSize = function() return { w = 20, h = 10 } end,
    paintTo = function(_, _bb, x, y) painted = { x = x, y = y } end,
}
local card = Box:new{ style = bold.card, width = 100, height = 50, child }
Assert.eq(card:getSize().w, 103)
Assert.eq(card:getSize().h, 53)
local bb = Kit.canvas()
card:paintTo(bb, 10, 20)
Assert.eq(#bb.ops, 3)
Assert.eq(bb.ops[1].op, "rect")
Assert.eq(bb.ops[1].x, 13, "阴影右下偏移")
Assert.eq(bb.ops[1].c, 0x00)
Assert.eq(bb.ops[2].op, "rect")
Assert.eq(bb.ops[2].x, 10)
Assert.eq(bb.ops[2].c, 0xFF)
Assert.eq(bb.ops[3].op, "border")
Assert.eq(bb.ops[3].bw, 2)
Assert.eq(painted.x, 10 + 40)
Assert.eq(painted.y, 20 + 20)
Assert.eq(card.dimen.x, 10, "绘制回写坐标，供点击命中")

-- bg_alpha < 100：不铺底色，改为按比例提亮下层。
bb = Kit.canvas()
Box:new{ style = { bg = 0xFF }, width = 40, height = 20, bg_alpha = 30, child }:paintTo(bb, 5, 6)
Assert.eq(bb.ops[1].op, "lighten")
Assert.eq(bb.ops[1].w, 40)

-- 不给宽高：按子件加内边距撑开。
local auto = Box:new{ style = bold.card, padding = 5, child }
Assert.eq(auto.box_w, 30)
Assert.eq(auto.box_h, 20)

-- soft 卡片：无阴影、无边框只画底；圆角夹到短边一半。
Kit.use("soft")
local soft = Theme.current()
local flat = Box:new{ style = soft.card, width = 100, height = 20 }
bb = Kit.canvas()
flat:paintTo(bb, 0, 0)
Assert.eq(#bb.ops, 1)
Assert.eq(bb.ops[1].c, 0xEE)
Assert.eq(bb.ops[1].r, 10)
Assert.eq(flat:getSize().w, 100)

-- 圆角框裁掉子件冒出四角的像素，角外颜色保持绘制前的底。
local pixels = {}
local function pixkey(px, py) return px .. ":" .. py end
local round_bb = {
    getWidth = function() return 20 end,
    getHeight = function() return 20 end,
    getPixel = function(_, px, py)
        local value = pixels[pixkey(px, py)] or 9
        return { getColorRGB32 = function() return value end }
    end,
    setPixel = function(_, px, py, color) pixels[pixkey(px, py)] = color end,
    paintRoundedRect = function() end,
    paintBorder = function() end,
}
local fill = {
    getSize = function() return { w = 20, h = 20 } end,
    paintTo = function(_, canvas, px, py)
        for row = 0, 19 do
            for col = 0, 19 do canvas:setPixel(px + col, py + row, 0) end
        end
    end,
}
Box:new{ style = { bg = 1, radius = 8, border = 0, shadow = 0 }, width = 20, height = 20, fill }
    :paintTo(round_bb, 0, 0)
Assert.eq(pixels["0:0"], 9, "角外还回底色")
Assert.eq(pixels["10:10"], 0, "圆内留下子件")

-- 有阴影时底角也还原成绘制前的底，不能抄成阴影色（否则底边像直角）。
pixels = {}
local shadow_bb = {
    getWidth = function() return 24 end,
    getHeight = function() return 24 end,
    getPixel = function(_, px, py)
        local value = pixels[pixkey(px, py)] or 9
        return { getColorRGB32 = function() return value end }
    end,
    setPixel = function(_, px, py, color) pixels[pixkey(px, py)] = color end,
    paintRoundedRect = function(_, x, y, _w, _h, color, _r)
        -- 阴影偏右下 2px：只把阴影区涂成 7，模拟真实阴影占住底角。
        for row = y, y + _h - 1 do
            for col = x, x + _w - 1 do
                if pixels[pixkey(col, row)] == nil then pixels[pixkey(col, row)] = color end
            end
        end
    end,
    paintBorder = function() end,
}
Box:new{
    style = { bg = 1, radius = 8, border = 0, shadow = 2, shadow_color = 7 },
    width = 20, height = 20, fill,
}:paintTo(shadow_bb, 0, 0)
Assert.eq(pixels["0:0"], 9, "顶角仍是页底")
Assert.eq(pixels["0:19"], 9, "底角还原页底，不是阴影色")
Assert.eq(pixels["19:19"], 9, "右下角同理")
Assert.eq(pixels["10:10"], 0, "圆内留下子件")

-- 无 bg 的样式什么都不画（透明表面）。
bb = Kit.canvas()
Box:new{ style = {}, width = 10, height = 10 }:paintTo(bb, 0, 0)
Assert.len(bb.ops, 0)

-- 进度条：高度取令牌，百分比夹到 0–100。
Kit.use("paper")
local bar = Progress:new{ width = 100, percent = 40 }
Assert.eq(bar:getSize().h, 4)
bb = Kit.canvas()
bar:paintTo(bb, 0, 0)
Assert.eq(#bb.ops, 2)
Assert.eq(bb.ops[1].w, 100, "轨道")
Assert.eq(bb.ops[1].c, 0xDD)
Assert.eq(bb.ops[2].w, 40, "填充")
bar:setPercent(150)
Assert.eq(bar.percent, 100)
bar:setPercent(-5)
Assert.eq(bar.percent, 0)
bar:setPercent(nil)
Assert.eq(bar.percent, 0)
bb = Kit.canvas()
bar:paintTo(bb, 0, 0)
Assert.eq(#bb.ops, 1, "0% 不画填充")

-- bold：带 2px 边框，填充在框内，边框最后画。
Kit.use("bold")
bar = Progress:new{ width = 100, percent = 50 }
Assert.eq(bar:getSize().h, 10)
bb = Kit.canvas()
bar:paintTo(bb, 0, 0)
Assert.eq(#bb.ops, 3)
Assert.eq(bb.ops[2].x, 2)
Assert.eq(bb.ops[2].w, 48)
Assert.eq(bb.ops[2].h, 6)
Assert.eq(bb.ops[3].op, "border")

-- 显式高度优先于令牌。
Assert.eq(Progress:new{ width = 50, height = 18 }:getSize().h, 18)

return true
