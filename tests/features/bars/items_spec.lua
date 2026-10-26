--[[--
阅读页栏组件：目录过滤与文案。
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["gettext"] = function()
    return function(text) return text end
end
package.preload["l10n"] = function()
    return { apply = function() end }
end

package.loaded["features.bars.items"] = nil
local Items = require("features.bars.items")

local top = Items.catalog("top")
local bottom = Items.catalog("bottom")
local top_ids, bottom_ids = {}, {}
for i = 1, #top do top_ids[top[i].id] = true end
for i = 1, #bottom do bottom_ids[bottom[i].id] = true end
Assert.is_true(top_ids.chapter)
Assert.is_true(top_ids.clock)
Assert.is_nil(top_ids.progress_bar)
Assert.is_true(bottom_ids.progress_bar)
Assert.is_true(bottom_ids.percent)

local ctx = Items.sampleContext()
Assert.eq(Items.text("chapter", ctx), "第三章 初见")
Assert.eq(Items.text("title", ctx), "示例书名")
Assert.eq(Items.text("clock", ctx), "12:34")
Assert.eq(Items.text("percent", ctx), "42%")
Assert.eq(Items.text("chapter_idx", ctx), "第 3/10 章")
Assert.eq(Items.text("page", ctx), "120/320")
Assert.eq(Items.text("remaining", ctx), "约 30 分钟")
Assert.eq(Items.text("progress_bar", ctx), "")
Assert.eq(Items.text("percent", { percent = 150 }), "100%")
Assert.eq(Items.text("percent", { percent = -3 }), "0%")
Assert.eq(Items.text("page", { page = 1 }), "")
Assert.eq(Items.text("chapter_idx", { chapter_idx = 3 }), "")
Assert.eq(Items.text("chapter_page", ctx), "本章 5/18")
Assert.eq(Items.text("chapter_page", { chapter_page = 5 }), "", "缺本章页数不显示")
Assert.is_true(top_ids.chapter_page)
Assert.is_true(bottom_ids.chapter_page)

-- 进度条用真实主题 Progress 画：它是自绘 Widget，没有 free（曾因 bar:free() 每次重绘崩阅读页）
do
    local Kit = require("support.widget_stubs")
    Kit.install()
    package.loaded["ui.themes.widgets.progress"] = nil
    local bb = Kit.canvas()
    Items.paint(bb, 0, 0, 300, 20, { { id = "progress_bar", align = "left" } }, { percent = 40 }, { bar_h = 6, gap = 4 })
    Assert.eq(bb.ops[1].op, "rect", "进度条画出了轨道")
    Assert.eq(bb.ops[1].w, 300, "唯一的 flex 条目占满宽度")

    -- 图标：电量按档位选图标、文字跟在图标后；Wi-Fi 开图标时只画图标
    local TextWidget = require("ui/widget/textwidget")
    local orig_paint = TextWidget.paintTo
    local painted = {}
    TextWidget.paintTo = function(self, _bb, px)
        painted[#painted + 1] = { text = self.text, x = px, xtext = self.use_xtext }
    end
    package.loaded["ui.themes.widgets.icon"] = { face = function(size) return { icon = size } end }
    Items.paint(bb, 0, 0, 300, 20,
        { { id = "battery", align = "left" }, { id = "wifi", align = "right" } },
        { battery = 50, charging = false, wifi = false },
        { face = { orig_size = 14 }, gap = 4, icons = true })
    local icon_gap = require("device").screen:scaleBySize(2)
    Assert.eq(painted[1].text, "battery_android_3")
    Assert.is_true(painted[1].xtext, "图标名靠 rlig 合成字形，必须走 xtext")
    Assert.eq(painted[2].text, "50%")
    Assert.eq(painted[2].x, #"battery_android_3" * 5 + icon_gap)
    Assert.eq(painted[3].text, "wifi_off")
    Assert.eq(painted[3].x, 300 - #"wifi_off" * 5, "只有图标的条目贴右边")
    Assert.len(painted, 3)

    -- 居中：相对整栏绝对居中；多项按布局顺序成组
    painted = {}
    Items.paint(bb, 0, 0, 300, 20,
        { { id = "clock", align = "center" } },
        { clock = "12:34" },
        { face = { orig_size = 14 }, gap = 4 })
    Assert.eq(painted[1].text, "12:34")
    Assert.eq(painted[1].x, math.floor((300 - #"12:34" * 5) / 2), "单条居中")

    painted = {}
    Items.paint(bb, 0, 0, 300, 20,
        { { id = "clock", align = "center" }, { id = "percent", align = "center" } },
        { clock = "12:34", percent = 42 },
        { face = { orig_size = 14 }, gap = 4 })
    local group_w = #"12:34" * 5 + 4 + #"42%" * 5
    Assert.eq(painted[1].x, math.floor((300 - group_w) / 2), "居中组起点")
    Assert.eq(painted[2].x, painted[1].x + #"12:34" * 5 + 4)

    TextWidget.paintTo = orig_paint
    package.loaded["ui.themes.widgets.icon"] = nil
end

-- 图标名随状态变化；开图标时文案省掉前后缀
Assert.eq(Items.glyph("battery", { battery = 100 }), "battery_android_full")
Assert.eq(Items.glyph("battery", { battery = 3 }), "battery_android_0")
Assert.eq(Items.glyph("battery", { battery = 60, charging = true }), "battery_android_bolt")
Assert.eq(Items.glyph("wifi", { wifi = true }), "wifi")
Assert.eq(Items.glyph("brightness", { brightness = 80 }), "brightness_high")
Assert.is_nil(Items.glyph("clock", ctx), "时钟一眼可读，不配图标")
Assert.eq(Items.text("chapter_page", ctx, true), "5/18")
Assert.eq(Items.text("chapter_idx", ctx, true), "3/10")
Assert.eq(Items.text("wifi", ctx, true), "")
Assert.eq(Items.text("wifi", ctx), "Wi-Fi")
Assert.eq(Items.text("battery", ctx), "85%")
Assert.eq(Items.text("memory", { memory = 512 }), "运存 512M")
Assert.eq(Items.text("memory", { memory = 1536 }, true), "1.5G", "开图标省前缀、超 1G 换算")
Assert.eq(Items.glyph("memory", { memory = 512 }), "memory")

return true
