--[[--
主题 HTML 正文：KOReader HtmlBoxWidget（MuPDF 排版）外包一层，套上与 DictQuickLookup 相同的词典基础 CSS
（Noto Sans、行高 1.3、列表缩进）+ 词典自带 css，字号跟主题正文字号。固定宽高，按高度分页，
页码交给调用方的 Pager；点到链接回调 on_link(link)。

  local box = Html.widget({ width = w, height = h, html = def, css = dict_css, dir = res_dir,
      on_link = function(link) … end, transparent = true })
  box.page_count; box:setPageNumber(2)

@module koplugin.book.ui.themes.widgets.html
--]]

local ffi = require("ffi")
local Device = require("device")
local Geom = require("ui/geometry")
local Theme = require("ui.themes")

local TYPE_BB8 = 1
local TYPE_BBRGB24 = 4
local TYPE_BBRGB32 = 5
local uint8_ro = ffi.typeof("const uint8_t*")
local uint8_rw = ffi.typeof("uint8_t*")

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

--- 真机 FFI BlitBuffer 扫描线直拷：跳过逐像素 getPixel / Color cdata / setPixelClamped 路径。
---@param dest any
---@param source any
---@param x number
---@param y number
---@param w number
---@param h number
---@return boolean
local function paintOverFFI(dest, source, x, y, w, h)
    if type(dest) ~= "cdata" or type(source) ~= "cdata" then return false end
    if not dest.getType or not source.getType then return false end
    local bb_type = source:getType()
    if bb_type ~= dest:getType() then return false end
    if bb_type ~= TYPE_BB8 and bb_type ~= TYPE_BBRGB24 and bb_type ~= TYPE_BBRGB32 then return false end
    if source:getRotation() ~= 0 or dest:getRotation() ~= 0 then return false end
    if source:getInverse() ~= 0 or dest:getInverse() ~= 0 then return false end

    local sw, sh = source:getWidth(), source:getHeight()
    local dw, dh = dest:getWidth(), dest:getHeight()
    w, h = math.min(w, sw), math.min(h, sh)
    local ix, iy = math.floor(x), math.floor(y)
    local sx0 = ix < 0 and -ix or 0
    local sy0 = iy < 0 and -iy or 0
    local dx0 = ix < 0 and 0 or ix
    local dy0 = iy < 0 and 0 or iy
    local cw = math.min(w - sx0, dw - dx0)
    local ch = math.min(h - sy0, dh - dy0)
    if cw <= 0 or ch <= 0 then return true end

    local src_base = ffi.cast(uint8_ro, source.data)
    local dst_base = ffi.cast(uint8_rw, dest.data)
    local src_stride = tonumber(source.stride)
    local dst_stride = tonumber(dest.stride)
    if bb_type == TYPE_BB8 then
        for row = 0, ch - 1 do
            local sp = src_base + (sy0 + row) * src_stride + sx0
            local dp = dst_base + (dy0 + row) * dst_stride + dx0
            for col = 0, cw - 1 do
                local v = sp[col]
                if v < 0xF0 then dp[col] = v end
            end
        end
        return true
    end
    local bpp = bb_type == TYPE_BBRGB32 and 4 or 3
    for row = 0, ch - 1 do
        local sp = src_base + (sy0 + row) * src_stride + sx0 * bpp
        local dp = dst_base + (dy0 + row) * dst_stride + dx0 * bpp
        for col = 0, (cw - 1) * bpp, bpp do
            local r, g, b = sp[col], sp[col + 1], sp[col + 2]
            if r < 0xF0 or g < 0xF0 or b < 0xF0 then
                dp[col] = r
                dp[col + 1] = g
                dp[col + 2] = b
                if bpp == 4 then dp[col + 3] = sp[col + 3] end
            end
        end
    end
    return true
end

--- 把 HtmlBox 位图叠到已有底上：纸白像素不写，下层壁纸或页面底得以保留。
--- 真机同格式非旋转位图走 FFI 扫描线快路径；其余（旋转、反色、测试桩）退回逐像素路径。
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
    if w <= 0 or h <= 0 then return end
    if paintOverFFI(dest, source, x, y, w, h) then return end
    if not source.getPixel or not dest.setPixelClamped then return end
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

---@param opts { width: integer, height: integer, html: string, css: string|nil, dir: string|nil, on_link: fun(link: table)|nil, transparent?: boolean|(fun(): boolean) }
---@return table HtmlBoxWidget
function Html.widget(opts)
    -- 用到才加载（MuPDF FFI），纯文字查词不付这份开销。
    local box = require("ui/widget/htmlboxwidget"):new{
        dimen = Geom:new{ x = 0, y = 0, w = opts.width, h = opts.height },
        html_link_tapped_callback = opts.on_link,
    }
    box:setContent(opts.html, BASE_CSS .. (opts.css or ""), Html.fontPx(), nil, nil, opts.dir)
    if opts.transparent then
        local transparent = opts.transparent
        function box:paintTo(bb, x, y)
            self.dimen.x = x
            self.dimen.y = y
            if self._render then self:_render() end
            local size = self.getSize and self:getSize() or self.dimen
            if not self.bb then return end
            local use_alpha = type(transparent) == "function" and transparent() or transparent == true
            if not use_alpha and bb.blitFrom then
                bb:blitFrom(self.bb, x, y, 0, 0, size.w, size.h)
            else
                Html.paintOver(bb, self.bb, x, y, size.w, size.h)
            end
        end
    end
    return box
end

return Html
