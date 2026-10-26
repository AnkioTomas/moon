--[[-- 标题、书名与图标保留 RGB，正文保持灰度。 --]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
Kit.color_enabled = true
Kit.display.theme_color = 0x7038A0

local TextWidget = require("ui/widget/textwidget")
local gray, rgb = 0, 0
TextWidget.paintTo = function(self, bb, x, y)
    Assert.eq(bb:getWidth(), 600)
    bb:colorblitFrom({}, x, y, 0, 0, 10, 10, self.fgcolor)
end
local bb = {
    getWidth = function() return 600 end,
    colorblitFrom = function() gray = gray + 1 end,
    colorblitFromRGB32 = function(_self, _source, _x, _y, _ox, _oy, _w, _h, color)
        rgb = rgb + 1
        Assert.eq(color, Kit.display.theme_color)
    end,
}
local Text = require("ui.themes.widgets.text")
local title = Text.line("title", "窗口标题", { color = Kit.display.theme_color })
title:paintTo(bb, 0, 0)
Assert.eq(rgb, 1, "显式强调色走 RGB 字形着色")
local icon = require("ui.themes.widgets.icon").widget{ name = "home", size = 24, box = false }
icon:paintTo(bb, 0, 0)
Assert.eq(rgb, 2, "图标走 RGB 字形着色")
Text.line("body", "正文"):paintTo(bb, 0, 0)
Assert.eq(gray, 1, "正文保持灰度路径")
Text.line("title", "书名"):paintTo(bb, 0, 0)
Text.line("hero", "内容标题"):paintTo(bb, 0, 0)
Assert.eq(rgb, 4, "标题与书名使用强调色")
Text.line("title", "显式黑字", { color = 0 }):paintTo(bb, 0, 0)
Assert.eq(gray, 2, "调用方显式指定黑色时不被强调色覆盖")
local book_title = Text.box("title", "多行书名", 100)
local background, foreground
book_title._bb = { getHeight = function() return 10 end }
book_title:paintTo({
    paintRect = function(_self, _x, _y, _w, _h, color) background = color end,
    colorblitFromRGB32 = function(_self, _source, _x, _y, _ox, _oy, _w, _h, color) foreground = color end,
}, 0, 0)
Assert.eq(background, 255, "彩色多行标题保留原底色")
Assert.eq(foreground, Kit.display.theme_color, "多行书名按蒙版绘制强调色，不受 xtext 开关影响")
Assert.eq(TextWidget.paintTo, getmetatable(title).paintTo, "原生 TextWidget 不被全局修改")

local Chart = require("ui.widgets.chart")
local chart = Chart.bars{ width = 200, height = 100, values = { 20, 0 } }
Assert.len(Kit.find(chart, function(w) return w.style and w.style.bg == Kit.display.theme_color end), 1)

local canvas = Kit.canvas()
local painted = {}
canvas.paintRectRGB32 = function(_self, _x, _y, _w, _h, color) painted[#painted + 1] = color end
canvas.paintRect = function(_self, _x, _y, _w, _h, color) painted[#painted + 1] = color end
require("ui.widgets.heatmap"):new{
    width = 20, cols = { { { level = 0 }, { level = 4 }, false } },
}:paintTo(canvas, 0, 0)
Assert.eq(painted[1], 0xEE)
Assert.eq(painted[2], Kit.display.theme_color, "最深热力格使用主题色")
