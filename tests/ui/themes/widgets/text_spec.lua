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

do
    local images = {}
    package.loaded["ui.themes.widgets.image"] = {
        widget = function(opts)
            local image = {
                opts = opts,
                paintTo = function(self, _bb, x, y) self.painted = { x, y } end,
                free = function(self) self.freed = true end,
            }
            images[#images + 1] = image
            return image
        end,
    }
    local rich = Text.box("body", "甲[捂脸]乙\n[未知][捂脸]", 100, {
        face = { size = 10 }, height = 30, transparent = true,
        inline_images = { ["[捂脸]"] = { url = "https://pic.test/emoji.png", headers = { Referer = "fixture" } } },
    })
    Assert.eq(rich.text, "甲　乙\n[未知]　", "已知表情占一字宽，未知标记保留")
    Assert.len(images, 2, "同一表情重复出现要分别占位")
    local positions = {}
    rich.virtual_line_num = 1
    rich.vertical_string_list = { { end_offset = 3 }, { end_offset = 9 } }
    function rich:_getXYForCharPos(pos)
        positions[#positions + 1] = pos
        return pos == 2 and 10 or 50, pos == 2 and 0 or 10, pos == 2 and 1 or 2
    end
    rich:paintTo(Kit.canvas(), 5, 6)
    Assert.eq(positions[1], 2, "字符位置按 UTF-8 字符算，不按字节算")
    Assert.eq(positions[2], 9, "换行及未知占位符计入后续字符位置")
    Assert.eq(images[1].painted[1], 15)
    Assert.eq(images[2].painted[2], 16)
    Assert.eq(images[1].opts.headers.Referer, "fixture")
    images[1].painted, images[2].painted = nil, nil
    rich.vertical_string_list[1].idx_to_substitute_with_ellipsis = 2
    rich.height = 10
    rich:paintTo(Kit.canvas(), 0, 0)
    Assert.is_nil(images[1].painted, "被省略号替换的表情不画")
    Assert.is_nil(images[2].painted, "超出可见高度的表情不画")
    rich:free()
    Assert.is_true(images[1].freed and images[2].freed, "释放文字同时取消图片与迟到回调")

    local composite = Text.box("body", "甲😀👍🏽👩‍💻❤️乙", 100, { emoji = true })
    Assert.eq(composite.text, "甲　　　　乙", "复合 emoji 各占一个字符槽")
    Assert.matches(images[3].opts.src, "/1f600%.png$")
    Assert.matches(images[4].opts.src, "/1f44d%-1f3fd%.png$")
    Assert.matches(images[5].opts.src, "/1f469%-200d%-1f4bb%.png$")
    composite:free()
    Assert.eq(Text.box("body", "甲😀乙", 100).text, "甲😀乙", "其它控件不改变旧的文字行为")
end
