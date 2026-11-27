--[[-- 段评列表：显示方式 full 铺满，window 是居中小窗，点卡片外可关。 --]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
Kit.sections.reviews = { font_scale = 100 }

local Sheet = require("features.reviews.sheet")

local function open()
    return Sheet:new{
        snapshot = {},
        spot = { range = "", text = "原句", total = 0 },
    }
end

local full = open()
Assert.is_false(full.mask, "全屏不画遮罩")
Assert.eq(full[1].box_w, 600)
Assert.eq(full[1].box_h, 800)
Assert.eq(full.panel_w, 600)
Assert.eq(full.panel_h, 800)

Kit.sections.reviews.display = "window"
local win = open()
Assert.is_true(win.mask, "小窗带遮罩，点外面关闭")
Assert.eq(win.panel_w, 480, "宽度用标准弹窗宽")
Assert.eq(win.panel_h, math.floor(800 * 0.72))
Assert.eq(win[1].box_w, 480)
Assert.eq(win[1].box_h, win.panel_h)
Assert.is_true(win.inner_w < 480)
Assert.is_true(win.body_h > 0)
Assert.eq(win[1].style, require("ui.themes").current().dialog)
