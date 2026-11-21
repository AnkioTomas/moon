--[[--
主题 HTML 正文：KOReader HtmlBoxWidget（MuPDF 排版）外包一层，套上与 DictQuickLookup 相同的词典基础 CSS
（Noto Sans、行高 1.3、列表缩进）+ 词典自带 css，字号跟主题正文字号。固定宽高，按高度分页，
页码交给调用方的 Pager；点到链接回调 on_link(link)。

  local box = Html.widget({ width = w, height = h, html = def, css = dict_css, dir = res_dir,
      on_link = function(link) … end, transparent = true })
  box.page_count; box:setPageNumber(2)

@module koplugin.book.ui.themes.widgets.html
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local Theme = require("ui.themes")

---@class BookThemeHtml
local Html = {}

-- 背景透明写进 CSS 以便语义完整；MuPDF draw_new 仍会 fz_clear_pixmap_with_value(..., 0xff)
-- 铺一层不透明白纸，因此透明绘制必须在 paintTo 里扣掉纸白，不能只靠样式。
-- Markdown 表格等业务样式不要塞这里：经 opts.css 由调用方传入。
local BASE_CSS = [[
@page { margin: 0; font-family: 'Noto Sans'; background-color: transparent; }
html, body { margin: 0; line-height: 1.3; background-color: transparent; }
blockquote, dd { margin: 0 1em; }
ol, ul, menu { margin: 0; padding: 0 1.7em; }
]]

--- 从颜色对象取出 R/G/B。绝不能对 Color cdata 写 `color == nil` 或 `color.r == nil`：
--- LuaJIT 会走 Color.__eq，而 __eq 内部是 color:getColorRGB32()，对 nil 直接炸
---（真机 2026-11-21 10:36:15 Asia/Shanghai：ffi/blitbuffer.lua:601 attempt to index local 'color' (a nil value)，
--- 栈在 Html.isPaper / paintOver，Guard 关掉 Modal，表现为 README「根本打不开」）。
---@param color any
---@return number|nil, number|nil, number|nil
local function rgbOf(color)
    local typ = type(color)
    if typ == "nil" then return nil end
    if typ == "number" then
        if color <= 0xFF then return color, color, color end
        return math.floor(color / 0x10000) % 0x100,
            math.floor(color / 0x100) % 0x100,
            color % 0x100
    end
    if typ ~= "table" and typ ~= "cdata" then return nil end
    -- getPixel 给出的 Color 有 getR；这里不再 pcall——合法 Color 不会失败，失败应暴露。
    if type(color.getR) == "function" then
        local r = color:getR()
        if type(r) == "number" then
            local g = type(color.getG) == "function" and color:getG() or r
            local b = type(color.getB) == "function" and color:getB() or r
            if type(g) == "number" and type(b) == "number" then
                return r, g, b
            end
        end
        return nil
    end
    -- 仅普通 table 才能直接读字段；cdata 缺字段会报错，且不能与 nil 做 ==。
    if typ == "table" then
        if type(color.r) == "number" then
            return color.r, type(color.g) == "number" and color.g or 0,
                type(color.b) == "number" and color.b or 0
        end
        if type(color.a) == "number" then
            return color.a, color.a, color.a
        end
    end
    return nil
end

--- 接近纸白（含抗锯齿浅边）。用于判断 HtmlBox 位图里哪些像素不该盖住下层壁纸。
---@param color any
---@return boolean
function Html.isPaper(color)
    if type(color) == "nil" then return true end
    local r, g, b = rgbOf(color)
    if type(r) ~= "number" then return false end
    return r >= 0xF0 and g >= 0xF0 and b >= 0xF0
end

--- 把 HtmlBox 位图叠到已有底上：纸白像素不写，下层壁纸或页面底得以保留。
--- 墨水屏常见灰阶 number 走快路径，避免每像素进 Color 分支。
---@param dest table BlitBuffer
---@param source table BlitBuffer
---@param x number
---@param y number
---@param width number|nil
---@param height number|nil
function Html.paintOver(dest, source, x, y, width, height)
    if not dest or not source then return end
    local w = width or (source.getWidth and source:getWidth()) or 0
    local h = height or (source.getHeight and source:getHeight()) or 0
    if w <= 0 or h <= 0 or not source.getPixel or not dest.setPixelClamped then return end
    for row = 0, h - 1 do
        for col = 0, w - 1 do
            local color = source:getPixel(col, row)
            local typ = type(color)
            if typ == "number" then
                if color <= 0xFF then
                    if color < 0xF0 then
                        dest:setPixelClamped(x + col, y + row, color)
                    end
                else
                    local r = math.floor(color / 0x10000) % 0x100
                    local g = math.floor(color / 0x100) % 0x100
                    local b = color % 0x100
                    if r < 0xF0 or g < 0xF0 or b < 0xF0 then
                        dest:setPixelClamped(x + col, y + row, color)
                    end
                end
            elseif not Html.isPaper(color) then
                dest:setPixelClamped(x + col, y + row, color)
            end
        end
    end
end

--- 翻页后丢掉上一页的绘制缓存。HtmlBoxWidget:_render 在 bb 仍在时会直接返回，
--- 只改 page_number 或 setDirty 不会换掉已画出的那一页。
---@param box table|nil
function Html.invalidatePage(box)
    if type(box) == "table" and box.freeBb then
        box:freeBb()
    end
end

--- MuPDF 默认字号（像素）：主题正文逻辑字号 → Font 字号 → 屏幕像素，与 Text 正文同大。
---@return integer
function Html.fontPx()
    return Device.screen:scaleBySize(Theme.fontSize(Theme.current().font.body))
end

---@param opts { width: integer, height: integer, html: string, css: string|nil, dir: string|nil, on_link: fun(link: table)|nil, transparent?: boolean }
---@return table HtmlBoxWidget
function Html.widget(opts)
    -- 用到才加载（MuPDF FFI），纯文字查词不付这份开销。
    local box = require("ui/widget/htmlboxwidget"):new{
        dimen = Geom:new{ x = 0, y = 0, w = opts.width, h = opts.height },
        html_link_tapped_callback = opts.on_link,
    }
    box:setContent(opts.html, BASE_CSS .. (opts.css or ""), Html.fontPx(), nil, nil, opts.dir)
    if opts.transparent then
        function box:paintTo(bb, x, y)
            self.dimen.x = x
            self.dimen.y = y
            if self._render then self:_render() end
            local size = self.getSize and self:getSize() or self.dimen
            if self.bb then
                Html.paintOver(bb, self.bb, x, y, size.w, size.h)
            end
        end
    end
    return box
end

return Html
