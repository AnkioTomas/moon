--[[--
锁屏离屏渲染：背景图片 + 文本/图形块写为 PNG。

封面和进度是 image / rule。kind=widget 只留给自绘块（引言、倾斜海报）。

@module koplugin.book.features.lockscreen.render
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local ImageWidget = require("ui/widget/imagewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Paths = require("utils.paths")
local Layout = require("features.lockscreen.layout")
local Screen = require("device").screen

local M = {}

-- 显式灰度文字、背景和装饰不染色；强调块与未指定颜色的粗体标题共用主题色。
---@param block table
---@param fallback ffi.cdata*
---@param title boolean|nil
---@return ffi.cdata*
local function blockColor(block, fallback, title)
    if (block.accent or title) and Screen.isColorEnabled and Screen:isColorEnabled() then
        local Theme = require("ui.themes")
        return Theme.color(Theme.current().color.accent)
    end
    return block.color or fallback
end

--- 将 widget 绘制到画布；越过任一画布边缘时裁剪，避免 blit 越界。借用 widget，不释放。
---@param bb BlitBuffer 用于绘制的 Blitbuffer 画布
---@param block table 包含 widget 与目标 x/y 坐标的绘制块
---@param canvas_w number 目标画布宽度，单位像素
---@param canvas_h number 目标画布高度，单位像素
function M.paintWidget(bb, block, canvas_w, canvas_h)
    local widget = block.widget
    if not widget or type(widget.paintTo) ~= "function" then
        error("invalid lockscreen widget block")
    end
    local x = math.floor(block.x or 0)
    local y = math.floor(block.y or 0)
    if x >= canvas_w or y >= canvas_h then
        return
    end
    local size = widget:getSize()
    local ww, wh = size.w, size.h
    local src_x = math.max(0, -x)
    local src_y = math.max(0, -y)
    local dst_x = math.max(0, x)
    local dst_y = math.max(0, y)
    local visible_w = math.min(ww - src_x, canvas_w - dst_x)
    local visible_h = math.min(wh - src_y, canvas_h - dst_y)
    if visible_w <= 0 or visible_h <= 0 then
        return
    end
    if src_x == 0 and src_y == 0 and visible_w == ww and visible_h == wh then
        widget:paintTo(bb, x, y)
        return
    end
    ---@type BlitBuffer
    ---@diagnostic disable-next-line: assign-type-mismatch
    local tmp = Blitbuffer.new(ww, wh, Blitbuffer.TYPE_BBRGB32)
    tmp:fill(Blitbuffer.COLOR_WHITE)
    local ok, err = pcall(function()
        widget:paintTo(tmp, 0, 0)
        bb:blitFrom(tmp, dst_x, dst_y, src_x, src_y, visible_w, visible_h)
    end)
    tmp:free()
    if not ok then
        error(err)
    end
end


--- fill() 会先把颜色收成灰度再铺开，彩屏上的 RGB 底会变成一条灰。
--- Color8 仍走 fill；RGB 走 paintRectRGB32，保持设计稿颜色。
---@param bb BlitBuffer
---@param width number
---@param height number
---@param fill BlitColor|nil
local function fillCanvas(bb, width, height, fill)
    fill = fill or Blitbuffer.COLOR_WHITE
    if Blitbuffer.isColor8(fill) then
        bb:fill(fill)
    else
        bb:paintRectRGB32(0, 0, width, height, fill)
    end
end

--- 离屏画一张 PNG 并原子替换；画布及临时文件归本次调用，失败保留原文件。
---@param path string 目标 PNG 路径
---@param width number 目标宽度，单位像素
---@param height number 目标高度，单位像素
---@param paint fun(bb: BlitBuffer)
---@return boolean, any
local function writePNG(path, width, height, paint, transparent)
    assert(width > 0 and width == math.floor(width), "invalid image width")
    assert(height > 0 and height == math.floor(height), "invalid image height")
    local bb
    local tmp = path .. ".part"
    -- 画的是文件不是屏幕：ImageWidget 等在夜间模式会预先反色去抵消整屏反色，
    -- 离屏写 PNG 时照做就存成底片。绘制期间关掉 night_mode，结束（含出错）恢复。
    local night = Screen.night_mode
    Screen.night_mode = false
    local ok, err = xpcall(function()
        local dir = path:match("(.+)/[^/]+$")
        if dir then
            local created, reason = Paths.ensureDir(dir)
            if not created then error("cannot create PNG directory " .. dir .. ": " .. tostring(reason)) end
        end
        -- 灰度屏用 BB8：整屏画布 RGB32 要 8 MiB，灰度 PNG 也小得多。透明背景只有 RGB32 带 alpha。
        local channels = (transparent or (Screen.isColorEnabled and Screen:isColorEnabled())) and 4 or 1
        bb = Blitbuffer.new(width, height,
            channels == 4 and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8)
        ---@diagnostic disable-next-line: cast-type-mismatch
        ---@cast bb BlitBuffer
        if not transparent then bb:fill(Blitbuffer.COLOR_WHITE) end
        paint(bb)
        -- 新画布无旋转、无行尾填充；直接编码，避免 writePNG 吞掉编码器错误和额外拷贝整屏。
        local encoded, reason = require("ffi/png").encodeToFile(tmp,
            require("ffi").cast("const unsigned char *", bb.data), width, height, channels)
        if not encoded then error("cannot write PNG " .. tmp .. ": " .. tostring(reason)) end
        local renamed, reason = os.rename(tmp, path)
        if not renamed then error(reason or "rename failed") end
    end, debug.traceback)
    Screen.night_mode = night
    if bb then bb:free() end
    if not ok then os.remove(tmp) end
    return ok, err
end

--- 取可用字体。指定文件打不开时回退 cfont，绝不把 nil 交给 TextBoxWidget。
---@param font string|nil
---@param size number|nil
---@param faceindex number|nil
---@return table|nil
function M.getFace(font, size, faceindex)
    local face = Font:getFace(font or "cfont", size, faceindex)
    if face then return face end
    if font ~= "cfont" then
        face = Font:getFace("cfont", size)
        if face then return face end
    end
    return Font:getFace("NotoSans-Regular.ttf", size)
end

--- 组装 TextBoxWidget 参数；line_height 只有显式给出时才写入，避免 nil 覆盖默认 0.3。
---@param text string
---@param width number
---@param size number
---@param bold boolean|nil
---@param opts { face?: string, faceindex?: number, align?: string, justified?: boolean, line_height?: number }|nil
---@return table
local function textBoxOpts(text, width, size, bold, opts)
    opts = opts or {}
    local args = {
        text = tostring(text or ""),
        face = M.getFace(opts.face or "cfont", size, opts.faceindex),
        width = width,
        alignment = opts.align or "left",
        bold = bold == true,
    }
    if opts.justified == true then args.justified = true end
    if opts.line_height ~= nil then args.line_height = opts.line_height end
    return args
end

--- 按实际渲染参数测量文本高度，供样式计算动态布局。
---@param text string
---@param width number
---@param size number
---@param bold boolean|nil
---@param opts { face?: string, faceindex?: number, align?: string, justified?: boolean, line_height?: number }|nil
---@return number
function M.measureText(text, width, size, bold, opts)
    local args = textBoxOpts(text, width, size, bold, opts)
    if not args.face then
        -- 连 cfont 都没有时不要去构造 TextBoxWidget（getAdjustedFace 会对 nil face 崩溃）。
        opts = opts or {}
        local leading = 1 + (opts.line_height or 0.3)
        local w = math.max(1, width or 1)
        local px = math.max(1, size or 1)
        -- 无字体时按近似字数估高：UTF-8 中文大约 3 字节一字。
        local chars = math.max(1, math.ceil(#tostring(text or "") / 3))
        local per = math.max(1, math.floor(w / px))
        return math.max(px, math.ceil(chars / per) * px * leading)
    end
    local widget = TextBoxWidget:new(args)
    local height = widget:getSize().h
    widget:free()
    return height
end

--- 绘制背景图片；图片缺失时保留纯白底并由调用方决定是否报错。
---@param bb BlitBuffer 目标 Blitbuffer
---@param path string|nil 背景图片路径；nil 时使用纯色底
---@param w number 输出宽度
---@param h number 输出高度
---@param fill table|nil 纯色底颜色，缺省白色
---@param contain boolean|nil 整图缩进画布、两侧留底色；缺省铺满裁切
---@return boolean, any
local function paintBackground(bb, path, w, h, fill, contain, decoded, transparent)
    if not transparent then fillCanvas(bb, w, h, fill or Blitbuffer.COLOR_WHITE) end
    if not path then
        return true
    end
    -- ImageWidget 解码失败时会换成 checkerboard，不能仅凭 getSize
    -- 判断成功。先用 RenderImage 解码，再把同一块图交给 ImageWidget
    -- 做居中裁切，失败时直接让本次组合失败并保留旧封面。
    local RenderImage = require("ui/renderimage")
    local source
    local image
    local ok, err = pcall(function()
        source = decoded or RenderImage:renderImageFile(path, false)
        if not source then
            error("cannot decode background: " .. tostring(path))
        end
        local iw, ih = source:getWidth(), source:getHeight()
        if not iw or not ih or iw <= 0 or ih <= 0 then
            error("cannot decode background: " .. tostring(path))
        end
        image = ImageWidget:new{
            image = source,
            image_disposable = true,
            width = w,
            height = h,
            scale_factor = (contain and math.min or math.max)(w / iw, h / ih),
            -- 透明底直接拷贝（含 alpha），混合会保留画布的全透明。
            alpha = not transparent,
        }
        image:paintTo(bb, 0, 0)
    end)
    if image then
        image:free()
    elseif source and source.free then
        source:free()
    end
    return ok, err
end

--- 将文本块绘制到离屏缓冲。
---@param bb BlitBuffer 目标 Blitbuffer
---@param block table 文本块描述
---@param w number 输出宽度
local function paintText(bb, block, w)
    local x = block.x or math.floor(w * 0.08)
    local width = block.width or (w - x * 2)
    -- Color* cdata 带 __eq，写 `color == nil` 会进 metamethod 对 nil 调 getColorRGB32 炸掉
    -- （票根粗体 + MUTED 色就是这条路径）。用 not 判缺省即可。
    local color = blockColor(block, Blitbuffer.COLOR_BLACK, block.bold and not block.color)
    local mask_text = block.box == false or not Blitbuffer.isColor8(color)
    local opts = textBoxOpts(block.text, width, block.size or 24, block.bold, block)
    opts.fgcolor = mask_text and Blitbuffer.COLOR_WHITE or color
    opts.bgcolor = mask_text and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local widget = TextBoxWidget:new(opts)
    local size = widget:getSize()
    local y = block.y or 0
    if block.box ~= false then
        local pad = block.padding or 10
        bb:paintRect(x - pad, y - pad, width + pad * 2, size.h + pad * 2, Blitbuffer.COLOR_WHITE)
    end
    if mask_text then
        -- 白字黑底作覆盖度蒙版，背景透出，RGB 字形也不会被原生绘制转灰。
        local mask = widget._bb
        local paint = Blitbuffer.isColor8(color) and bb.colorblitFrom or bb.colorblitFromRGB32
        paint(bb, mask, x, y, 0, 0, mask:getWidth(), mask:getHeight(), color)
    else
        widget:paintTo(bb, x, y)
    end
    widget:free()
end

--- 绘制圆角矩形；radius 为 0/nil 时退化为直角。
---@param bb BlitBuffer
---@param x number
---@param y number
---@param width number
---@param height number
---@param radius number|nil
local function paintRect(bb, x, y, width, height, color, radius)
    radius = math.max(0, math.floor(tonumber(radius) or 0))
    if radius > 0 then
        local paint = Blitbuffer.isColor8(color) and bb.paintRoundedRect or bb.paintRoundedRectRGB32
        paint(bb, x, y, width, height, color, radius)
    else
        local paint = Blitbuffer.isColor8(color) and bb.paintRect or bb.paintRectRGB32
        paint(bb, x, y, width, height, color)
    end
end

--- 在两色之间插值，不走 Theme.mix（会补饱和，把设计稿渐变推离原色）。
---@param from BlitColor
---@param to BlitColor
---@param t number
---@return BlitColor
local function mixColors(from, to, t)
    if t <= 0 then return from end
    if t >= 1 then return to end
    local function rgb(color)
        if Blitbuffer.isColor8(color) then
            return color.a, color.a, color.a
        end
        if color.getColorRGB32 then
            local c = color:getColorRGB32()
            return c.r, c.g, c.b
        end
        return 0, 0, 0
    end
    local r1, g1, b1 = rgb(from)
    local r2, g2, b2 = rgb(to)
    local r = math.max(0, math.min(255, math.floor(r1 + (r2 - r1) * t + 0.5)))
    local g = math.max(0, math.min(255, math.floor(g1 + (g2 - g1) * t + 0.5)))
    local b = math.max(0, math.min(255, math.floor(b1 + (b2 - b1) * t + 0.5)))
    if Blitbuffer.isColor8(from) and Blitbuffer.isColor8(to) then
        return Blitbuffer.Color8(r)
    end
    return Blitbuffer.ColorRGB32(r, g, b, 0xFF)
end

--- 在圆角矩形范围内叠一层半透明白：圆角行逐行收窄，中段一次混合。
---@param bb BlitBuffer
---@param radius number|nil
---@param by number 白色不透明度 0..1
local function lightenRounded(bb, x, y, width, height, radius, by)
    radius = math.max(0, math.min(math.floor(tonumber(radius) or 0),
        math.floor(width / 2), math.floor(height / 2)))
    for row = 0, radius - 1 do
        local dy = radius - row - 0.5
        local inset = radius - math.floor(math.sqrt(radius * radius - dy * dy) + 0.5)
        bb:lightenRect(x + inset, y + row, width - inset * 2, 1, by)
        bb:lightenRect(x + inset, y + height - 1 - row, width - inset * 2, 1, by)
    end
    bb:lightenRect(x, y + radius, width, height - radius * 2, by)
end

--- 取出颜色的 RGB 分量（0–255）。
---@param color BlitColor
---@return number, number, number
local function rgbOf(color)
    if Blitbuffer.isColor8(color) then
        return color.a, color.a, color.a
    end
    if color.getColorRGB32 then
        local c = color:getColorRGB32()
        return c.r, c.g, c.b
    end
    return 0, 0, 0
end

--- 把带不透明度的颜色叠到已有像素上（用于风景页脚遮罩、静影暗角）。
---@param alpha number 0..1
local function blendRect(bb, x, y, width, height, color, alpha)
    alpha = tonumber(alpha) or 0
    if alpha <= 0 or width <= 0 or height <= 0 then return end
    local canvas_w = bb.getWidth and bb:getWidth() or 0
    local canvas_h = bb.getHeight and bb:getHeight() or 0
    if x < 0 then width = width + x; x = 0 end
    if y < 0 then height = height + y; y = 0 end
    if canvas_w > 0 then width = math.min(width, canvas_w - x) end
    if canvas_h > 0 then height = math.min(height, canvas_h - y) end
    if width <= 0 or height <= 0 then return end
    if alpha >= 1 then
        paintRect(bb, x, y, width, height, color, 0)
        return
    end
    local cr, cg, cb = rgbOf(color)
    local typ = bb.getType and bb:getType() or nil
    if typ == Blitbuffer.TYPE_BBRGB32 and bb.data then
        local ffi = require("ffi")
        local data = ffi.cast("uint8_t *", bb.data)
        local stride = tonumber(bb.stride)
        local inv = 1 - alpha
        for row = 0, height - 1 do
            local dest = (y + row) * stride + x * 4
            for col = 0, width - 1 do
                local i = dest + col * 4
                data[i] = math.max(0, math.min(255, math.floor(data[i] * inv + cr * alpha + 0.5)))
                data[i + 1] = math.max(0, math.min(255, math.floor(data[i + 1] * inv + cg * alpha + 0.5)))
                data[i + 2] = math.max(0, math.min(255, math.floor(data[i + 2] * inv + cb * alpha + 0.5)))
            end
        end
        return
    end
    local target = math.floor(0.299 * cr + 0.587 * cg + 0.114 * cb + 0.5)
    local inv = 1 - alpha
    for row = 0, height - 1 do
        for col = 0, width - 1 do
            local px = bb:getPixel(x + col, y + row)
            local g = 255
            if type(px) == "number" then
                g = px
            elseif px then
                if px.getColor8 then
                    local ok, c8 = pcall(function() return px:getColor8() end)
                    if ok and c8 and type(c8.a) == "number" then g = c8.a end
                elseif type(px.a) == "number" then
                    g = px.a
                end
            end
            local v = math.max(0, math.min(255, math.floor(g * inv + target * alpha + 0.5)))
            if typ == Blitbuffer.TYPE_BBRGB32 then
                bb:setPixel(x + col, y + row, Blitbuffer.ColorRGB32(v, v, v, 0xFF))
            else
                bb:setPixel(x + col, y + row, Blitbuffer.Color8(v))
            end
        end
    end
end

--- 垂直渐变；blend=true 时按两端不透明度叠在已有画面上。
---@param alpha_from number|nil 0..1，缺省 1
---@param alpha_to number|nil 0..1，缺省与 from 相同
local function paintVGradient(bb, x, y, width, height, from, to, blend, alpha_from, alpha_to)
    if not from or width <= 0 or height <= 0 then return end
    to = to or from
    alpha_from = alpha_from == nil and 1 or alpha_from
    alpha_to = alpha_to == nil and alpha_from or alpha_to
    if height == 1 then
        if blend then
            blendRect(bb, x, y, width, 1, mixColors(from, to, 0), alpha_from)
        else
            paintRect(bb, x, y, width, 1, from, 0)
        end
        return
    end
    for row = 0, height - 1 do
        local t = row / (height - 1)
        local color = mixColors(from, to, t)
        local a = alpha_from + (alpha_to - alpha_from) * t
        if blend then
            blendRect(bb, x, y + row, width, 1, color, a)
        else
            paintRect(bb, x, y + row, width, 1, color, 0)
        end
    end
end

--- 小图逐行盒式模糊（先缩小再模糊，近似大半径）。
---@param src BlitBuffer
---@param radius number
---@return BlitBuffer
local function blurBuffer(src, radius)
    radius = math.max(1, math.floor(tonumber(radius) or 1))
    local sw, sh = src:getWidth(), src:getHeight()
    local typ = src.getType and src:getType() or Blitbuffer.TYPE_BBRGB32
    ---@type BlitBuffer
    ---@diagnostic disable-next-line: assign-type-mismatch
    local work = src:copy()
    ---@type BlitBuffer
    ---@diagnostic disable-next-line: assign-type-mismatch
    local tmp = Blitbuffer.new(sw, sh, typ)
    local function pass(from, dest, horizontal)
        dest:fill(Blitbuffer.COLOR_BLACK)
        for y = 0, sh - 1 do
            for x = 0, sw - 1 do
                local r, g, b, n = 0, 0, 0, 0
                for k = -radius, radius do
                    local sx, sy = x, y
                    if horizontal then sx = x + k else sy = y + k end
                    if sx >= 0 and sx < sw and sy >= 0 and sy < sh then
                        local px = from:getPixel(sx, sy)
                        if type(px) ~= "number" and px and px.getColorRGB32 then
                            local c = px:getColorRGB32()
                            r, g, b = r + c.r, g + c.g, b + c.b
                        else
                            local v = type(px) == "number" and px or (px and px.a or 0)
                            r, g, b = r + v, g + v, b + v
                        end
                        n = n + 1
                    end
                end
                if n > 0 then
                    r, g, b = math.floor(r / n + 0.5), math.floor(g / n + 0.5), math.floor(b / n + 0.5)
                    if typ == Blitbuffer.TYPE_BBRGB32 then
                        dest:setPixel(x, y, Blitbuffer.ColorRGB32(r, g, b, 0xFF))
                    else
                        dest:setPixel(x, y, Blitbuffer.Color8(r))
                    end
                end
            end
        end
    end
    pass(work, tmp, true)
    pass(tmp, work, false)
    tmp:free()
    return work
end

local kept = {}
local keptImage

--- 按 cover 方式把图片铺进矩形（可指定锚点、放大裁切、先缩小再模糊）。
local function paintCoverImage(bb, block, x, y, width, canvas_w, canvas_h)
    local height = block.height or width
    if width <= 0 or height <= 0 then return end
    local RenderImage = require("ui/renderimage")
    local source
    local owned = false
    if block.keep then
        source = keptImage(block.file)
    else
        source = assert(RenderImage:renderImageFile(assert(block.file, "image block file required"), false),
            "cannot decode image: " .. tostring(block.file))
        owned = true
    end
    local iw, ih = source:getWidth(), source:getHeight()
    if not iw or not ih or iw <= 0 or ih <= 0 then
        if owned and source.free then source:free() end
        error("cannot decode image: " .. tostring(block.file))
    end
    local typ = bb.getType and bb:getType() or Blitbuffer.TYPE_BBRGB32
    local work = source
    local free_work = false
    if block.blur then
        -- 先缩到短边约 64px，模糊后再放大，近似大半径高斯，避免在全分辨率上逐像素跑。
        local short = math.min(iw, ih)
        local small_w, small_h = iw, ih
        if short > 64 then
            local s = 64 / short
            small_w = math.max(8, math.floor(iw * s + 0.5))
            small_h = math.max(8, math.floor(ih * s + 0.5))
            ---@type BlitBuffer
            ---@diagnostic disable-next-line: assign-type-mismatch
            local small = Blitbuffer.new(small_w, small_h, typ)
            local ImageWidget = require("ui/widget/imagewidget")
            local scaler = ImageWidget:new{
                image = source,
                image_disposable = false,
                width = small_w,
                height = small_h,
                scale_factor = 0,
            }
            scaler:paintTo(small, 0, 0)
            scaler:free()
            work = blurBuffer(small, 2)
            small:free()
            free_work = true
            iw, ih = small_w, small_h
        else
            work = blurBuffer(source, 2)
            free_work = true
        end
    end
    local zoom = block.zoom or 1
    local scale = math.max(width / iw, height / ih) * zoom
    local sw, sh = iw * scale, ih * scale
    local ax = block.anchor_x
    if ax == nil then ax = 0.5 end
    local ay = block.anchor_y
    if ay == nil then ay = 0.5 end
    -- CSS background-position：图上 ax/ay 的点对齐到框内同一比例位置。
    local off_x = width * ax - sw * ax
    local off_y = height * ay - sh * ay
    ---@type BlitBuffer
    ---@diagnostic disable-next-line: assign-type-mismatch
    local scaled = Blitbuffer.new(math.max(1, math.floor(sw + 0.5)), math.max(1, math.floor(sh + 0.5)), typ)
    local ImageWidget = require("ui/widget/imagewidget")
    local scaler = ImageWidget:new{
        image = work,
        image_disposable = false,
        width = scaled:getWidth(),
        height = scaled:getHeight(),
        scale_factor = 0,
    }
    scaler:paintTo(scaled, 0, 0)
    scaler:free()
    local src_x = math.max(0, math.floor(-off_x + 0.5))
    local src_y = math.max(0, math.floor(-off_y + 0.5))
    local dst_x = math.max(0, x + math.floor(off_x + 0.5))
    local dst_y = math.max(0, y + math.floor(off_y + 0.5))
    local vis_w = math.min(scaled:getWidth() - src_x, width - (dst_x - x), (bb.getWidth and bb:getWidth() or canvas_w) - dst_x)
    local vis_h = math.min(scaled:getHeight() - src_y, height - (dst_y - y), (bb.getHeight and bb:getHeight() or canvas_h) - dst_y)
    if vis_w > 0 and vis_h > 0 then
        bb:blitFrom(scaled, dst_x, dst_y, src_x, src_y, vis_w, vis_h)
    end
    scaled:free()
    if free_work and work and work.free then work:free() end
    if owned and source.free then source:free() end
end

-- keep 图块（锁屏 logo）解码一次常驻：每次锁屏都画同一张小图，不必重复解码。只存小图，按文件一份。
---@param file string
---@return BlitBuffer
function keptImage(file)
    if not kept[file] then
        kept[file] = assert(require("ui/renderimage"):renderImageFile(file, false), "cannot decode image: " .. file)
    end
    return kept[file]
end

--- 分发非文本图形块：线、柱、卡片、票根缺口、图片和离屏 widget。
--- 封面 / 进度条不再走 DSL；主体通过 kind=widget 复用 ui.widgets。
---@param bb BlitBuffer 目标 Blitbuffer
---@param block table 图形块描述
---@param w number 输出宽度
---@param h number 输出高度
---@param background BlitBuffer|nil 绘制主体前的背景副本
local function paintShape(bb, block, w, h, background)
    local x = block.x or math.floor(w * 0.08)
    local y = block.y or 0
    local width = block.width or (w - x * 2)
    if block.kind == "rule" then
        -- DESIGN：分割线 #55，默认 1px，不抢内容
        paintRect(bb, x, y, width, block.height or 1,
            blockColor(block, Blitbuffer.COLOR_GRAY_5))
    elseif block.kind == "panel" then
        -- DESIGN：浅卡可带 8px 圆角 + 2px 轻阴影（#DD）
        local height = block.height or 1
        local radius = block.radius or 0
        if block.lighten then
            -- 半透明卡：背景透出来，不画阴影
            lightenRounded(bb, x, y, width, height, radius, block.lighten)
            return
        end
        local color = blockColor(block, Blitbuffer.COLOR_WHITE)
        if block.shadow then
            local s = type(block.shadow) == "number" and block.shadow or 2
            paintRect(bb, x + s, y + s, width, height, Blitbuffer.COLOR_GRAY_D, radius)
        end
        paintRect(bb, x, y, width, height, color, radius)
    elseif block.kind == "hgradient" then
        -- 水平渐变：彩屏按列插值，避免分段色块。
        local height = block.height or 1
        local colors = block.colors or {}
        local from, to = colors[1], colors[2] or colors[1]
        if not from then
            return
        end
        if not to or from == to or width <= 1 then
            paintRect(bb, x, y, width, height, from, 0)
            return
        end
        for col = 0, width - 1 do
            local t = col / (width - 1)
            paintRect(bb, x + col, y, 1, height, mixColors(from, to, t), 0)
        end
    elseif block.kind == "vgradient" then
        -- 垂直渐变：彩屏按行插值；blend 时叠在已有画面上（页脚遮罩）。
        local height = block.height or 1
        local colors = block.colors or {}
        local from, to = colors[1], colors[2] or colors[1]
        if from then
            paintVGradient(bb, x, y, width, height, from, to, block.blend == true,
                block.alpha_from, block.alpha_to)
        end
    elseif block.kind == "overlay" then
        -- 半透明色块，叠在已有画面上。
        blendRect(bb, x, y, width, block.height or 1,
            blockColor(block, Blitbuffer.COLOR_BLACK), block.alpha or 0.5)
    elseif block.kind == "border" then
        local height = block.height or 1
        local bw = math.max(1, math.floor(tonumber(block.border or block.weight) or 1))
        local color = blockColor(block, Blitbuffer.COLOR_BLACK)
        local radius = block.radius or 0
        local paint = Blitbuffer.isColor8(color) and bb.paintBorder or bb.paintBorderRGB32
        paint(bb, x, y, width, height, bw, color, radius)
    elseif block.kind == "vbar" then
        -- DESIGN 锁屏日柱：默认无满高浅轨；value 为相对槽高的比例，也可由调用方直接给实心柱高
        local height = block.height or 1
        local radius = block.radius or 0
        local track = block.track
        if track then
            paintRect(bb, x, y, width, height, track, radius)
        end
        local filled = math.floor(height * math.max(0, math.min(1, block.value or 0)))
        if filled > 0 then
            paintRect(bb, x, y + height - filled, width, filled,
                blockColor(block, Blitbuffer.COLOR_BLACK), radius)
        end
    elseif block.kind == "cutout_circle" then
        if not background then error("cutout_circle requires background snapshot") end
        local radius = math.max(1, math.floor(tonumber(block.radius) or 1))
        local center_x, center_y = math.floor(x), math.floor(y)
        for dy = -radius, radius do
            local half = math.floor(math.sqrt(radius * radius - dy * dy))
            local src_x = math.max(0, center_x - half)
            local src_y = center_y + dy
            local span = math.min(w, center_x + half + 1) - src_x
            if src_y >= 0 and src_y < h and span > 0 then
                bb:blitFrom(background, src_x, src_y, src_x, src_y, span, 1)
            end
        end
    elseif block.kind == "image" then
        if block.cover or block.anchor_y or block.anchor_x or block.blur or block.zoom then
            paintCoverImage(bb, block, x, y, width, w, h)
        else
        local image = ImageWidget:new{
            file = not block.keep and assert(block.file, "image block file required") or nil,
            image = block.keep and keptImage(block.file) or nil,
            image_disposable = not block.keep,
            -- 海报墙一次几十张封面；进全局 ImageCache 会挤掉阅读器 / 桌面的缓存，画完就没用了。
            file_do_cache = false,
            width = width,
            height = block.height,
            scale_factor = block.scale_factor or 0,
            alpha = block.alpha == true,
        }
        local ok, err = pcall(function()
            if not block.circle then
                image:paintTo(bb, x, y)
                return
            end
            -- 圆形遮罩：先画到临时画布，再按圆的弦逐行拷到主画布，角上露出底色。
            local hh = block.height or width
            if width <= 0 or hh <= 0 then return end
            local tmp_type = bb.getType and bb:getType() or Blitbuffer.TYPE_BBRGB32
            local tmp = Blitbuffer.new(width, hh, tmp_type)
            image:paintTo(tmp, 0, 0)
            local canvas_w = bb.getWidth and bb:getWidth() or w
            local canvas_h = bb.getHeight and bb:getHeight() or h
            local cx, cy = (width - 1) / 2, (hh - 1) / 2
            local radius = math.min(width, hh) / 2
            for row = 0, hh - 1 do
                local inside = radius * radius - (row - cy) * (row - cy)
                if inside >= 0 then
                    local half = math.sqrt(inside)
                    local x0 = math.max(0, math.ceil(cx - half))
                    local x1 = math.min(width - 1, math.floor(cx + half))
                    local dst_x, dst_y = x + x0, y + row
                    local src_x, span = x0, x1 - x0 + 1
                    if dst_x < 0 then
                        span = span + dst_x
                        src_x = src_x - dst_x
                        dst_x = 0
                    end
                    if dst_y >= 0 and dst_y < canvas_h and dst_x < canvas_w and span > 0 then
                        span = math.min(span, canvas_w - dst_x)
                        if span > 0 then
                            bb:blitFrom(tmp, dst_x, dst_y, src_x, row, span, 1)
                        end
                    end
                end
            end
            tmp:free()
        end)
        image:free()
        if not ok then error(err) end
        end
    elseif block.kind == "widget" then
        M.paintWidget(bb, block, w, h)
    end
end

--- 释放主体创建的离屏 widget，避免封面解码缓冲和容器留在内存中。
---@param blocks table[]
local function freeWidgets(blocks)
    local freed = {}
    for _idx, block in ipairs(blocks or {}) do
        local widget = block.widget
        if widget and not freed[widget] and type(widget.free) == "function" then
            freed[widget] = true
            widget:free()
        end
    end
end

--- 画一块主体：有 kind 走图形，否则当文字。
---@param bb BlitBuffer
---@param block table
---@param w number
---@param h number
---@param background BlitBuffer|nil
function M.paintBlock(bb, block, w, h, background)
    if block.kind then
        paintShape(bb, block, w, h, background)
    else
        paintText(bb, block, w)
    end
end

--- 解码后的背景是否带透明像素：只有 RGB32 有 alpha，遇到第一个非不透明像素即停。
---@param source any 解码器返回的位图或不支持的图像对象
---@return boolean
function M.hasAlpha(source)
    if not source.getType or source:getType() ~= Blitbuffer.TYPE_BBRGB32 then return false end
    local data = require("ffi").cast("uint8_t *", source.data)
    for y = 0, source:getHeight() - 1 do
        local row = y * tonumber(source.stride)
        for x = 0, source:getWidth() - 1 do
            if data[row + x * 4 + 3] < 255 then return true end
        end
    end
    return false
end

--- 预乘 alpha 像素压到白底（不透明），主体照常画在白底上；返回对应的白底值。
local function onWhite(c, a) return c + 255 - a end

--- 透明背景两遍处理：first=true 时把透明背景压白（bb 变不透明，bg 留原样）；
--- first=false 时，主体没画过的像素（仍等于压白值）还原成背景的直通 alpha，画过的保持不透明。
---@param bb BlitBuffer
---@param bg BlitBuffer
---@param first boolean
local function alphaPass(bb, bg, first)
    local ffi = require("ffi")
    local d = ffi.cast("uint8_t *", bb.data)
    local s = ffi.cast("uint8_t *", bg.data)
    local stride = tonumber(bb.stride)
    for y = 0, bb:getHeight() - 1 do
        for x = 0, bb:getWidth() - 1 do
            local i = y * stride + x * 4
            local a = s[i + 3]
            if a < 255 then
                local r, g, b = onWhite(s[i], a), onWhite(s[i + 1], a), onWhite(s[i + 2], a)
                if first then
                    d[i], d[i + 1], d[i + 2], d[i + 3] = r, g, b, 255
                elseif d[i] == r and d[i + 1] == g and d[i + 2] == b then
                    -- MuPDF 给的是预乘值，PNG 要直通 alpha
                    local k = a > 0 and 255 / a or 0
                    d[i] = math.min(255, math.floor(s[i] * k + 0.5))
                    d[i + 1] = math.min(255, math.floor(s[i + 1] * k + 0.5))
                    d[i + 2] = math.min(255, math.floor(s[i + 2] * k + 0.5))
                    d[i + 3] = a
                end
            end
        end
    end
end

--- 生成 PNG，成功后原子替换。
--- 原子替换保证 KOReader 不会读到半张 compose.png。
--- 背景 = 图片（path，contain 时整图缩进）+ 自绘块（blocks，如海报墙）；主体 blocks 画在其上，
--- cutout_circle 挖出的是整个背景。
---@param path string
---@param background {path: string|nil, contain: boolean|nil, blocks: table[]|nil}|nil
---@param blocks table[]
---@param fill table|nil 无背景图时的底色，缺省白色
--- 背景图带透明像素时输出带 alpha 的 PNG：背景透明处、且主体没画到的地方保持透明，
--- 第三个返回值为 true；主体自己画的卡片/文字都不透明。
---@return boolean, any, boolean|nil
function M.write(path, background, blocks, fill)
    local w, h = Layout.portraitSize()
    local backdrop = background and background.blocks or {}
    local background_copy, alpha_bg, source
    local bg_path = background and background.path
    if bg_path then
        source = require("ui/renderimage"):renderImageFile(bg_path, false) --[[@as BlitBuffer]]
    end
    local transparent = source ~= nil and M.hasAlpha(source)
    local ok, err = writePNG(path, w, h, function(bb)
        local bg_ok, bg_err = paintBackground(bb, bg_path, w, h, fill,
            background and background.contain, source, transparent)
        source = nil -- 已交给 ImageWidget 释放
        if not bg_ok then error(bg_err) end
        if transparent then
            alpha_bg = bb:copy()
            alphaPass(bb, alpha_bg, true)
        end
        for _idx, block in ipairs(backdrop) do M.paintBlock(bb, block, w, h) end
        for _idx, block in ipairs(blocks) do
            if block.kind == "cutout_circle" then
                background_copy = bb:copy()
                break
            end
        end
        for _idx, block in ipairs(blocks) do
            M.paintBlock(bb, block, w, h, background_copy)
        end
        if alpha_bg then alphaPass(bb, alpha_bg, false) end
    end, transparent)
    if source then source:free() end
    if alpha_bg then alpha_bg:free() end
    freeWidgets(backdrop)
    freeWidgets(blocks)
    if background_copy then background_copy:free() end
    return ok, err, ok and transparent or nil
end

--- 按指定尺寸写 PNG（分享卡片等非整屏图）。画布与块坐标都是物理像素。
---@param path string
---@param width number
---@param height number
---@param blocks table[]
---@param fill table|nil 底色，缺省白色
---@return boolean, any
function M.writeSize(path, width, height, blocks, fill)
    local ok, err = writePNG(path, width, height, function(bb)
        fillCanvas(bb, width, height, fill)
        for _idx, block in ipairs(blocks or {}) do
            M.paintBlock(bb, block, width, height)
        end
    end)
    freeWidgets(blocks)
    return ok, err
end

return M
