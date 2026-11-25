--[[--
ui.themes.widgets.html / text_viewer HTML 详情：纸白不覆盖下层，翻页必须换掉正文渲染来源。

@module tests.ui.themes.widgets.html_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

package.preload["gettext"] = package.preload["gettext"] or function() return function(text) return text end end

local BB = require("ffi/blitbuffer")
local Html = require("ui.themes.widgets.html")

-- 纸白判断：灰阶和打包 RGB。
Assert.is_true(Html.isPaper(0xFF))
Assert.is_true(Html.isPaper(0xF0))
Assert.is_false(Html.isPaper(0x00))
Assert.is_false(Html.isPaper(0x20))
Assert.is_true(Html.isPaper(0xF0F0F0))
Assert.is_false(Html.isPaper(0x000000))
Assert.is_false(Html.isPaper(0x202020))

-- 复现真实 BlitBuffer Color：getPixel 返回带 __eq 的对象。LuaJIT cdata 的 `color == nil`
-- 会进 __eq，而 Color.__eq 会对另一侧调 getColorRGB32（nil 即崩）。table 对 nil 不会走
-- __eq，所以这里用「对非 Color 操作数直接 error」的元方法，并走 getR/getG/getB。
local function FakeColor(r, g, b)
    return setmetatable({
        getR = function(self) return r end,
        getG = function(self) return g end,
        getB = function(self) return b end,
    }, {
        __eq = function(_self, other)
            if type(other) ~= "table" then
                error("attempt to index local 'color' (a nil value)")
            end
            return false
        end,
    })
end
Assert.is_true(Html.isPaper(FakeColor(0xFF, 0xFF, 0xFF)))
Assert.is_true(Html.isPaper(FakeColor(0xF0, 0xF0, 0xF0)))
Assert.is_false(Html.isPaper(FakeColor(0x00, 0x00, 0x00)))
Assert.is_false(Html.isPaper(FakeColor(0x20, 0x20, 0x20)))
Assert.is_false(Html.isPaper(FakeColor(0x80, 0x80, 0x80)))

-- 透明绘制：下层「壁纸」色不被整块白底清掉，墨色像素写上去。
local paper, ink, wall = 255, 0, 0xCC
local dest = BB.new(8, 4)
dest:fill(wall)
local src = BB.new(8, 4)
src:fill(paper)
src:setPixel(2, 1, ink)
src:setPixel(3, 1, ink)
Html.paintOver(dest, src, 0, 0, 8, 4)
local wallpaper, written = 0, 0
for row = 0, 3 do
    for col = 0, 7 do
        local px = dest:getPixel(col, row)
        if px == wall then
            wallpaper = wallpaper + 1
        elseif px == ink then
            written = written + 1
        else
            Assert.is_true(false, "出现既非壁纸也非墨色的像素: " .. tostring(px))
        end
    end
end
Assert.eq(written, 2)
Assert.eq(wallpaper, 8 * 4 - 2)
Assert.eq(dest:getPixel(0, 0), wall, "纸白不得盖住底层")
Assert.eq(dest:getPixel(2, 1), ink)

-- 真机 FFI BlitBuffer 扫描线快路径（TYPE_BB8 与 TYPE_BBRGB32 + 边界裁切）。
do
    local ffi = require("ffi")
    pcall(ffi.cdef, [[
        typedef struct TestHtmlBB {
            unsigned int w;
            unsigned int h;
            size_t stride;
            uint8_t *data;
            int bb_type;
        } TestHtmlBB;
    ]])
    local mt = {
        __index = {
            getType = function(self) return self.bb_type end,
            getRotation = function() return 0 end,
            getInverse = function() return 0 end,
            getWidth = function(self) return tonumber(self.w) end,
            getHeight = function(self) return tonumber(self.h) end,
        },
    }
    pcall(ffi.metatype, "TestHtmlBB", mt)
    local function newBB(w, h, bb_type, bpp)
        local buf = ffi.new("uint8_t[?]", w * h * bpp)
        local bb = ffi.new("TestHtmlBB", w, h, w * bpp, buf, bb_type)
        return bb, buf
    end
    -- BB8: 保留底层 wall=0xCC，跳过 >=0xF0 纸白，只写墨色像素，并验证 x=-1 负偏移裁切。
    local d8, d8_buf = newBB(4, 2, 1, 1)
    local s8, s8_buf = newBB(4, 2, 1, 1)
    ffi.fill(d8_buf, 8, 0xCC)
    ffi.fill(s8_buf, 8, 0xFF)
    s8_buf[0] = 0x10 -- 被 x=-1 裁掉
    s8_buf[2] = 0x20 -- 落到 dest (1, 0)
    s8_buf[5] = 0xEF -- 落到 dest (0, 1)，刚好 < 0xF0 应写入
    s8_buf[6] = 0xF0 -- 纸白阈值，不得覆盖壁纸
    Html.paintOver(d8, s8, -1, 0, 4, 2)
    Assert.eq(d8_buf[0], 0xCC)
    Assert.eq(d8_buf[1], 0x20)
    Assert.eq(d8_buf[4], 0xEF)
    Assert.eq(d8_buf[5], 0xCC)

    -- BBRGB32: 4 字节/像素，彩色像素写入，纸白跳过。
    local d32, d32_buf = newBB(2, 1, 5, 4)
    local s32, s32_buf = newBB(2, 1, 5, 4)
    ffi.fill(d32_buf, 8, 0xAA)
    ffi.fill(s32_buf, 8, 0xFF)
    s32_buf[4], s32_buf[5], s32_buf[6], s32_buf[7] = 0x10, 0x20, 0x30, 0xFF
    Html.paintOver(d32, s32, 0, 0, 2, 1)
    Assert.eq(d32_buf[0], 0xAA, "BBRGB32 纸白不得覆盖底层")
    Assert.eq(d32_buf[4], 0x10)
    Assert.eq(d32_buf[5], 0x20)
    Assert.eq(d32_buf[6], 0x30)
end

-- 忠实复现 HtmlBoxWidget:_render 的位图缓存：只改 page_number 时仍画出旧页。
local Fake = {}
function Fake:new(o)
    o = o or {}
    o.page_number = o.page_number or 1
    o.page_count = o.page_count or 4
    o.dimen = o.dimen or { w = 8, h = 4 }
    o.bb = nil
    return setmetatable(o, { __index = Fake })
end
function Fake:getSize() return self.dimen end
function Fake:freeBb() self.bb = nil end
function Fake:free()
    self.freed = (self.freed or 0) + 1
    self:freeBb()
end
function Fake:setPageNumber(n)
    if n ~= self.page_number then
        self.page_number = n
        -- 有意不在这里 freeBb，对齐修复前的 HtmlBoxWidget 行为。
    end
end
function Fake:_render()
    if self.bb then return end
    local buf = BB.new(self.dimen.w, self.dimen.h)
    buf:fill(paper)
    -- 用第 page 列的墨点标记「这一页真正画出来的来源」。
    buf:setPixel(self.page_number, 0, ink)
    self.bb = buf
    self.rendered_from = self.page_number
end
function Fake:paintTo(bb, x, y)
    self:_render()
    Html.paintOver(bb, self.bb, x or 0, y or 0, self.dimen.w, self.dimen.h)
end

local function paintedColumn(box)
    local canvas = BB.new(box.dimen.w, box.dimen.h)
    canvas:fill(wall)
    box:paintTo(canvas, 0, 0)
    for col = 0, box.dimen.w - 1 do
        if canvas:getPixel(col, 0) == ink then return col, canvas end
    end
    return nil, canvas
end

local stale = Fake:new{}
local col, canvas = paintedColumn(stale)
Assert.eq(stale.rendered_from, 1)
Assert.eq(col, 1)
stale:setPageNumber(2)
col, canvas = paintedColumn(stale)
Assert.eq(stale.rendered_from, 1, "未丢缓存时仍按第 1 页渲染")
Assert.eq(col, 1)
Assert.eq(canvas:getPixel(0, 1), wall)

-- TextViewer / 调用方必须在 setPageNumber 之后 invalidate，正文来源才会变成新页。
local box = Fake:new{}
col = paintedColumn(box)
Assert.eq(col, 1)
Assert.eq(box.rendered_from, 1)
box:setPageNumber(2)
Html.invalidatePage(box)
col, canvas = paintedColumn(box)
Assert.eq(box.page_number, 2)
Assert.eq(box.rendered_from, 2, "invalidate 后应重新按第 2 页渲染")
Assert.eq(col, 2)
Assert.eq(canvas:getPixel(1, 0), wall, "旧页墨点不应残留")
Assert.eq(canvas:getPixel(0, 1), wall)

box:setPageNumber(4)
Html.invalidatePage(box)
col = paintedColumn(box)
Assert.eq(box.rendered_from, 4)
Assert.eq(col, 4)

box:setPageNumber(3)
Html.invalidatePage(box)
col = paintedColumn(box)
Assert.eq(box.rendered_from, 3)
Assert.eq(col, 3)

-- 接入 TextViewer：翻页走真实 Pager 点击，长文 1→2→4→3，页码和渲染来源一起变。
package.loaded["ui/widget/htmlboxwidget"] = nil
local set_content_calls = 0
function Fake:setContent()
    set_content_calls = set_content_calls + 1
    self.page_count = 4
    self.page_number = 1
    self.bb = nil
    self.rendered_from = nil
end
package.preload["ui/widget/htmlboxwidget"] = function()
    return { new = function(_, o) return Fake:new(o) end }
end
package.loaded["ui.themes.widgets.html"] = nil
package.loaded["ui.themes.widgets.text_viewer"] = nil
Html = require("ui.themes.widgets.html")
local TextViewer = require("ui.themes.widgets.text_viewer")

local long = string.rep("<p>段落</p>\n", 40)
local viewer = TextViewer:new{
    title = "月读书源：知音漫客",
    html = long,
    fullscreen = true,
    buttons = {
        { text = "取消", callback = function() end },
        { text = "重装", variant = "primary", callback = function() end },
    },
}
Assert.is_true(viewer._html_mode)
Assert.eq(set_content_calls, 1, "多页 HTML 只应排版一次，不再二次重复 setContent")
Assert.eq(viewer.pages, 4)
Assert.eq(viewer.page, 1)
Assert.eq(viewer.body.page_count, 4)

local function bodySource()
    local _, _canvas = paintedColumn(viewer.body)
    return viewer.body.rendered_from, viewer.body.page_number
end

local source, number = bodySource()
Assert.eq(source, 1)
Assert.eq(number, 1)
Assert.eq(viewer.page, 1)

local function pagerButtons()
    return Kit.find(viewer, function(w) return w.icon == "chevron_right" or w.icon == "chevron_left" end)
end
local function click(icon)
    local found
    for _i, btn in ipairs(pagerButtons()) do
        if btn.icon == icon then found = btn end
    end
    Assert.eq(type(found), "table", "找不到 " .. icon)
    Assert.is_true(found.enabled ~= false, icon .. " 在边界外仍应可点时才点")
    found.callback()
end

click("chevron_right")
source, number = bodySource()
Assert.eq(viewer.page, 2)
Assert.eq(number, 2)
Assert.eq(source, 2, "下一页必须换掉正文渲染来源，不能只改页码")

-- 跳到末页
click("chevron_right")
click("chevron_right")
source, number = bodySource()
Assert.eq(viewer.page, 4)
Assert.eq(number, 4)
Assert.eq(source, 4)

-- 末页右翻无效果（默认不循环时）
local before = viewer.page
local right
for _i, btn in ipairs(pagerButtons()) do
    if btn.icon == "chevron_right" then right = btn end
end
Assert.eq(right.enabled, false, "末页右箭头应进入边界态")
viewer:turn(1)
source, number = bodySource()
Assert.eq(viewer.page, before)
Assert.eq(source, 4)

click("chevron_left")
source, number = bodySource()
Assert.eq(viewer.page, 3)
Assert.eq(number, 3)
Assert.eq(source, 3, "前一页也必须换掉正文渲染来源")

-- 底栏按钮仍在
local labels = table.concat(Kit.texts(viewer), ",")
Assert.is_true(labels:find("取消", 1, true) ~= nil)
Assert.is_true(labels:find("重装", 1, true) ~= nil)

-- setContent / 关闭必须释放上一份 HtmlBox，避免 MuPDF 文档泄漏。
local first = viewer.body
Assert.eq(type(first.free), "function")
viewer:setContent({ html = "<p>第二份</p>", text = "第二份" })
Assert.eq(first.freed, 1, "替换正文应 free 旧 HtmlBox")
Assert.is_true(viewer.body ~= first)
local second = viewer.body
viewer:onCloseWidget()
Assert.eq(second.freed, 1, "关窗应 free 当前 HtmlBox")

-- 主题基础 CSS 不含 marketplace 表格类名；业务样式经 opts.css 追加。
do
    local seen = {}
    package.preload["ui/widget/htmlboxwidget"] = function()
        return {
            new = function(_, o)
                return setmetatable(o, {
                    __index = {
                        setContent = function(_self, _html, css)
                            seen.css = css
                            _self.page_count = 1
                            _self.page_number = 1
                        end,
                        freeBb = function() end,
                        free = function() end,
                    },
                })
            end,
        }
    end
    package.loaded["ui/widget/htmlboxwidget"] = nil
    package.loaded["ui.themes.widgets.html"] = nil
    local H = require("ui.themes.widgets.html")
    H.widget({ width = 10, height = 10, html = "<p>x</p>" })
    Assert.is_nil(seen.css:find("md%-table", 1))
    H.widget({ width = 10, height = 10, html = "<p>x</p>", css = "table.md-table{}" })
    Assert.is_true(seen.css:find("md%-table", 1) ~= nil)
    -- transparent 回调返回 false 且目标画布支持 blitFrom 时，直接走原生 blitFrom 不逐像素扫。
    local blitted = false
    local fast_box = H.widget({
        width = 8, height = 4, html = "<p>x</p>",
        transparent = function() return false end,
    })
    fast_box.bb = BB.new(8, 4)
    fast_box:paintTo({ blitFrom = function() blitted = true end }, 0, 0)
    Assert.is_true(blitted, "非透明白底应直走 blitFrom 快路径")
    package.loaded["ui/widget/htmlboxwidget"] = nil
    package.preload["ui/widget/htmlboxwidget"] = nil
    package.loaded["ui.themes.widgets.html"] = nil
end

return true
