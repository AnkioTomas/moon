--[[-- 超长段评预览可点开全文，全文分页不改变评论列表当前位置。
@module tests.features.reviews.sheet_content_spec
--]]
local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Text = require("ui.themes.widgets.text")
local box = Text.box
-- stub 的文字高度固定；按正文长度提供自然高度，限行后仍用原 stub。
Text.box = function(role, text, width, opts)
    local widget = box(role, text, width, opts)
    if not opts or not opts.max_lines then
        function widget:getSize() return { w = width, h = math.ceil(#text / 10) * 10 } end
    end
    return widget
end
local Sheet = require("features.reviews.sheet")
local theme = require("ui.themes").current()
local long = ("review text "):rep(250) .. "END-OF-REVIEW"
local fake = setmetatable({
    theme = theme, inner_w = 500, body_h = 200, cards = {}, page = 2,
    items = {
        { author = "Long author", content = long, likes = 10, time = 1 },
        { author = "Short author", content = "short", likes = 1, time = 1 },
    },
}, { __index = Sheet })

local card = fake:card(1)
Assert.eq(fake:card(1), card, "卡片缓存保留点击入口")
Assert.is_true(card:getSize().h <= fake.body_h)
Assert.is_true(type(card.onTapThemeArea) == "function")
card:onTapThemeArea()
local viewer = Kit.shown[#Kit.shown]
Assert.eq(viewer.title, "段评 · Long author")
Assert.eq(viewer.text, long, "全文不使用被截断的预览")
Assert.is_true(viewer.pages > 1, "同一条长评论可独立分页")
viewer:turn(1)
Assert.eq(viewer.page, 2)
Assert.eq(fake.page, 2, "全文翻页不前进到另一人的段评")
viewer:close()
Assert.eq(fake.page, 2)
Assert.is_nil(fake:card(2).onTapThemeArea, "短评论不增加无用点击区")

local image_url = "https://example.test/review.jpg"
local image_card = setmetatable({
    theme = theme, inner_w = 500, body_h = 200, cards = {},
    items = { { author = "Reviewer", content = "Short review", likes = 1, time = 1,
        images = { { url = image_url } } } },
}, { __index = Sheet }):card(1)
local image_tap = Kit.taps(image_card)[1]
Assert.is_true(image_tap ~= nil, "配图有独立点击入口")
image_tap:onTapThemeArea()
local viewer = Kit.shown[#Kit.shown]
Assert.is_true(viewer.close_on_tap, "全屏图可点按关闭")
local displayed_image = Kit.find(viewer, function(widget) return widget.src == image_url end)[1]
Assert.is_true(displayed_image ~= nil, "预览使用点击的图片地址")
Assert.is_true(displayed_image.image_opts.stretch, "全屏预览按比例缩进，不拉满变形")
viewer.close_callback()
Assert.is_true(displayed_image.cancelled, "关闭预览取消图片下载")
