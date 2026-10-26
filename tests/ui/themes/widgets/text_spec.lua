--[[--
ui.themes.widgets.text / Text.tint：彩色单行文字的代理画布必须接住第三方插件对 bb 的调用。

Text.tint 交给原生 TextWidget 的不是真画布，而是一层只改写 colorblitFrom 的代理。
插件覆写 TextWidget:paintTo 后会直接对收到的 bb 调别的方法（appearance 就调
colorblitFromRGB32），代理缺方法时每次绘制都抛错，被 guard 捕获后整屏空白。
这里模拟核心与插件两条绘制路径，确认代理对外行为与真画布一致。

@module tests.ui.themes.widgets.text_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
-- 只有彩色设备上主题才会把 accent 换成 RGB32，Text.tint 才会套代理。
Kit.color_enabled = true

local TextWidget = require("ui/widget/textwidget")
local Text = require("ui.themes.widgets.text")

local GLYPH = {
    getWidth = function() return 4 end,
    getHeight = function() return 6 end,
}

--- 让原生控件用指定方法在收到的画布上落一次字。
--- 核心 TextWidget 走 colorblitFrom；覆写过 paintTo 的插件走 colorblitFromRGB32 等。
local function paint_with(method)
    TextWidget.paintTo = function(self, bb, x, y)
        -- 与 appearance 的 TextWidget:paintTo 一致：先读宽度算截断，再按 RGB32 上色。
        local width = bb:getWidth() - x
        bb[method](bb, GLYPH, x, y, 0, 0, width, GLYPH:getHeight(), self.fgcolor)
    end
end

-- title 默认取 accent（RGB32），Text.line 会给它套上代理画布。
local widget = Text.line("title", "书名")

-- 核心路径：代理把灰度 colorblitFrom 改写成真画布的 colorblitFromRGB32。
paint_with("colorblitFrom")
local canvas = Kit.canvas()
widget:paintTo(canvas, 10, 20)
local op = canvas.ops[#canvas.ops]
Assert.eq(op.op, "colorblitRGB", "灰度上色应改走真画布的 RGB32")
Assert.eq(op.x, 10, "坐标原样透传")
Assert.eq(op.y, 20, "坐标原样透传")
Assert.eq(op.w, Kit.SCREEN_W - 10, "getWidth 透传真画布")

-- 插件路径：直调 colorblitFromRGB32 不能被代理吞掉（缺这个方法就是白屏）。
paint_with("colorblitFromRGB32")
canvas = Kit.canvas()
widget:paintTo(canvas, 30, 40)
op = canvas.ops[#canvas.ops]
Assert.eq(op.op, "colorblitRGB", "插件直调 colorblitFromRGB32 应透传")
Assert.eq(op.x, 30, "坐标原样透传")
Assert.eq(op.w, Kit.SCREEN_W - 30, "getWidth 透传真画布")

-- 其它画布方法同样透传，插件拿到的 bb 与真画布行为一致。
paint_with("lightenRect")
canvas = Kit.canvas()
widget:paintTo(canvas, 1, 2)
Assert.eq(canvas.ops[#canvas.ops].op, "lighten", "其它方法也应透传")

-- 灰度文字不套代理：仍直接落在真画布的灰度 colorblitFrom 上。
paint_with("colorblitFrom")
canvas = Kit.canvas()
local plain = Text.line("body", "正文", { color = 0x00 })
plain:paintTo(canvas, 5, 6)
Assert.eq(canvas.ops[#canvas.ops].op, "colorblit", "灰色文字走原生灰度路径")
