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

local M = {}

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
    local Screen = require("device").screen
    local night = Screen.night_mode
    Screen.night_mode = false
    local ok, err = xpcall(function()
        -- 灰度屏用 BB8：整屏画布 RGB32 要 8 MiB，灰度 PNG 也小得多。透明背景只有 RGB32 带 alpha。
        bb = Blitbuffer.new(width, height,
            (transparent or Screen:isColorEnabled()) and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8)
        ---@diagnostic disable-next-line: cast-type-mismatch
        ---@cast bb BlitBuffer
        if not transparent then bb:fill(Blitbuffer.COLOR_WHITE) end
        paint(bb)
        if bb:writePNG(tmp) == false then error("PNG write failed") end
        local renamed, reason = os.rename(tmp, path)
        if not renamed then error(reason or "rename failed") end
    end, debug.traceback)
    Screen.night_mode = night
    if bb then bb:free() end
    if not ok then os.remove(tmp) end
    return ok, err
end

--- 按实际渲染参数测量文本高度，供样式计算动态布局。
---@param text string
---@param width number
---@param size number
---@param bold boolean|nil
---@return number
function M.measureText(text, width, size, bold)
    local widget = TextBoxWidget:new{
        text = tostring(text or ""),
        face = Font:getFace("cfont", size),
        width = width,
        bold = bold == true,
    }
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
    if not transparent then bb:fill(fill or Blitbuffer.COLOR_WHITE) end
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
    local color = block.color or Blitbuffer.COLOR_BLACK
    local widget = TextBoxWidget:new{
        text = tostring(block.text or ""),
        face = Font:getFace(block.face or "cfont", block.size or 24),
        width = width,
        alignment = block.align or "left",
        -- 无框文字取黑字作覆盖度蒙版，着色交给 colorblitFrom
        fgcolor = block.box == false and Blitbuffer.COLOR_BLACK or color,
        bold = block.bold == true,
    }
    local size = widget:getSize()
    local y = block.y or 0
    if block.box ~= false then
        local pad = block.padding or 10
        bb:paintRect(x - pad, y - pad, width + pad * 2, size.h + pad * 2, Blitbuffer.COLOR_WHITE)
        widget:paintTo(bb, x, y)
    else
        -- TextBoxWidget:paintTo 会连白底整块贴上；反相后按字形覆盖度混合，背景才透得出来。
        local mask = widget._bb
        mask:invertRect(0, 0, mask:getWidth(), mask:getHeight())
        bb:colorblitFrom(mask, x, y, 0, 0, mask:getWidth(), mask:getHeight(), color)
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
        bb:paintRoundedRect(x, y, width, height, color, radius)
    else
        bb:paintRect(x, y, width, height, color)
    end
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

-- keep 图块（锁屏 logo）解码一次常驻：每次锁屏都画同一张小图，不必重复解码。只存小图，按文件一份。
local kept = {}
---@param file string
---@return BlitBuffer
local function keptImage(file)
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
        bb:paintRect(x, y, width, block.height or 1,
            block.color or Blitbuffer.COLOR_GRAY_5)
    elseif block.kind == "panel" then
        -- DESIGN：浅卡可带 8px 圆角 + 2px 轻阴影（#DD）
        local height = block.height or 1
        local radius = block.radius or 0
        if block.lighten then
            -- 半透明卡：背景透出来，不画阴影
            lightenRounded(bb, x, y, width, height, radius, block.lighten)
            return
        end
        local color = block.color or Blitbuffer.COLOR_WHITE
        if block.shadow then
            local s = type(block.shadow) == "number" and block.shadow or 2
            paintRect(bb, x + s, y + s, width, height, Blitbuffer.COLOR_GRAY_D, radius)
        end
        paintRect(bb, x, y, width, height, color, radius)
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
                block.color or Blitbuffer.COLOR_BLACK, radius)
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
        local ok, err = pcall(image.paintTo, image, bb, x, y)
        image:free()
        if not ok then error(err) end
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
    Paths.ensureScreensaverDir()
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

return M
