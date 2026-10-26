--[[--
ui.widgets.bookhero：缺省单行书名、右栏与封面等高；title_lines 多行书名截断；
内容比封面高时整卡随内容长高。
@module tests.ui.widgets.bookhero_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Widget = require("ui/widget/widget")

local desc_text = ""
package.preload["ui.widgets.book"] = function()
    return {
        title = function(book) return book.title end,
        author = function() return "作者" end,
        desc = function() return desc_text end,
        pct = function() return 0 end,
        cover = function(_, _, _, w, h) return Widget:new{ dimen = { w = w, h = h } } end,
    }
end

local Hero = require("ui.widgets.bookhero")
local long_title = string.rep("长", 30)

local function boxes(widget, out)
    out = out or {}
    if type(widget) ~= "table" then return out end
    if widget.getAllLineCount then out[#out + 1] = widget end
    for _idx, child in ipairs(widget) do boxes(child, out) end
    return out
end

local _w, h = Hero.widget(nil, nil, { title = long_title }, { width = 400, pad = 0, cover_width = 60, show_progress = false })
Assert.eq(h, 90, "缺省：整卡与封面（60×90）等高")
Assert.len(boxes((Hero.widget(nil, nil, { title = long_title }, { width = 400, pad = 0 }))), 0, "缺省单行书名")

local widget = Hero.widget(nil, nil, { title = long_title }, {
    width = 400, pad = 0, cover_width = 60, show_progress = false, title_lines = 3,
})
local title_box = boxes(widget)[1]
Assert.eq(title_box:getAllLineCount(), 9, "90 字节书名在桩里是 9 行")
Assert.eq(title_box:getVisLineCount(), 3, "最多 3 行")

_w, h = Hero.widget(nil, nil, { title = long_title }, {
    width = 400, pad = 0, cover_width = 20, show_progress = false, title_lines = 3,
})
Assert.is_true(h > 30, "右栏比封面（20×30）高时整卡随内容长高")

-- 英雄卡没有卡片底：简介多行文字不得拿页面白铺满矩形（壁纸上会成白斑）。
desc_text = "这是一段简介文字"
local desc_box = boxes((Hero.widget(nil, nil, { title = "书名" },
    { width = 400, pad = 0, cover_width = 60 })))[1]
desc_box._bb = { getHeight = function() return 10 end }
local rects, blits = 0, 0
desc_box:paintTo({
    paintRect = function() rects = rects + 1 end,
    paintRectRGB32 = function() rects = rects + 1 end,
    colorblitFrom = function() blits = blits + 1 end,
    colorblitFromRGB32 = function() blits = blits + 1 end,
}, 0, 0)
Assert.eq(rects, 0, "简介不铺底色")
Assert.eq(blits, 1, "简介只画字形")
desc_text = ""
