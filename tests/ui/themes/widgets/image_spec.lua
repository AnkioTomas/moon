--[[--
ui.themes.widgets.image 与 Row / List 的图片位：外框按令牌、图按边框内缩、
其余参数原样交给 ui.themes.widgets.image.core；行内缩略图高度夹进行高；status 可给控件。

@module tests.ui.themes.widgets.image_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("bold")

local Theme = require("ui.themes")
local Image = require("ui.themes.widgets.image")
local List = require("ui.themes.widgets.list")
local Row = require("ui.themes.widgets.row")

local function inner(box) return box[1] end

-- 外框 = width × height；bold 边框 2，图内缩 4；未给 style 取 image 令牌。
local t = Theme.current()
local ready = function() end
local img = Image.widget({ width = 120, height = 160, src = "/a.png", fallback = "书名",
    on_ready = ready, headers = { A = "b" }, alpha = false })
Assert.eq(img.style, t.image)
Assert.eq(img:getSize().w, 120)
Assert.eq(img:getSize().h, 160)
Assert.eq(inner(img):getSize().w, 116)
Assert.eq(inner(img):getSize().h, 156)
local o = inner(img).image_opts
Assert.eq(o.src, "/a.png")
Assert.eq(o.on_ready, ready)
Assert.eq(o.headers.A, "b")
Assert.is_false(o.alpha)
-- 占位文案：主题 caption + muted，宽度留 xs 边距（超宽由 TextWidget 截断）。
Assert.eq(o.fallback.text, "书名")
Assert.eq(o.fallback.fgcolor, t.color.muted)
Assert.eq(o.fallback.face.size, t.font.caption)
Assert.eq(o.fallback.max_width, 116 - t.space.xs * 2)
Assert.is_nil(Image.widget({ width = 10, height = 10, src = "x", fallback = "" })[1].image_opts.fallback,
    "空文案 = 空白占位")
local fb_widget = { getSize = function() return { w = 1, h = 1 } end }
Assert.eq(Image.widget({ width = 10, height = 10, src = "x", fallback = fb_widget })[1].image_opts.fallback,
    fb_widget, "控件占位原样透传")
Assert.eq(Image.fetchAsync, require("ui.themes.widgets.image.core").fetchAsync)

-- 换表面：soft 无边框，图不内缩。
Kit.use("soft")
t = Theme.current()
img = Image.widget({ width = 50, height = 50, src = "x", style = t.card })
Assert.eq(img.style, t.card)
Assert.eq(inner(img):getSize().w, 50)
Assert.eq(inner(Image.widget({ width = 36, height = 36, src = "x", style = {} })):getSize().w, 36, "空表面：无边框不内缩")

-- 三套主题 image 表面都是直角（位图压不住圆角）。
for _, id in ipairs(Theme.ids) do
    Assert.eq(Theme.get(id).image.radius, 0, id)
end

-- 行内缩略图：给多大取多大，但高度夹进行高 - 2 * xs。
local function thumb(row)
    return Kit.find(row, function(w) return w.src == "cover.png" end)[1]
end
local row = Row.widget({ width = 400, title = "书", image = "cover.png", image_w = 30, image_h = 200 })
local pic = thumb(row)
Assert.eq(pic:getSize().w, 30)
Assert.eq(pic:getSize().h, Row.height(false) - 2 * t.space.xs)
Assert.eq(row:getSize().h, Row.height(false), "图片不撑高行（List 分页按固定行高算）")
row = Row.widget({ width = 400, title = "书", image = "cover.png" })
Assert.eq(thumb(row):getSize().w, t.control.icon, "缺省缩略图 = 图标尺寸")

-- status 给控件：原样放进右侧，宽度取控件自身。
local preview = Kit.find(Row.widget({ width = 400, title = "x", status = "开" }), function(w) return w.text == "开" end)
Assert.len(preview, 1)
local custom = require("ui/widget/widget"):new{ dimen = { w = 77, h = 20 }, custom = true }
custom.getSize = function(self) return self.dimen end
row = Row.widget({ width = 400, title = "字体", status = custom })
Assert.len(Kit.find(row, function(w) return w == custom end), 1)

-- List 透传 image / widget（widget 优先于 mandatory）。
local list = List:new{ title = "壁纸", items = {
    { text = "a", image = "cover.png", widget = custom, mandatory = "不显示" },
} }
local cover = Kit.find(list, function(w) return w.src == "cover.png" end)
Assert.len(cover, 1)
Assert.len(Kit.find(list, function(w) return w == custom end), 1)
Assert.len(Kit.find(list, function(w) return w.text == "不显示" end), 0)

return true
