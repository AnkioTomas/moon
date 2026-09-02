--[[--
锁屏离屏渲染：背景图片 + 文本/图形块 + ui.components widget 写为 PNG。

普通主体可用纯数据块；需要与桌面一致的封面/进度等走 kind=widget，
由本文件把现成 widget 临时绘制到离屏画布。

@module koplugin.book.lockscreen.render
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local ImageWidget = require("ui/widget/imagewidget")
local logger = require("logger")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Paths = require("utils.paths")
local Layout = require("lockscreen.layout")

local M = {}

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
---@param bb userdata 目标 Blitbuffer
---@param path string|nil 背景图片路径；nil 时使用纯白背景
---@param w number 输出宽度
---@param h number 输出高度
---@return boolean, any
local function paintBackground(bb, path, w, h)
    bb:fill(Blitbuffer.COLOR_WHITE)
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
        source = RenderImage:renderImageFile(path, false)
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
            scale_factor = math.max(w / iw, h / ih),
            alpha = true,
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
---@param bb userdata 目标 Blitbuffer
---@param block table 文本块描述
---@param w number 输出宽度
local function paintText(bb, block, w)
    local x = block.x or math.floor(w * 0.08)
    local width = block.width or (w - x * 2)
    local widget = TextBoxWidget:new{
        text = tostring(block.text or ""),
        face = Font:getFace(block.face or "cfont", block.size or 24),
        width = width,
        alignment = block.align or "left",
        fgcolor = block.color or Blitbuffer.COLOR_BLACK,
        bold = block.bold == true,
    }
    local size = widget:getSize()
    if block.box ~= false then
        local pad = block.padding or 10
        bb:paintRect(x - pad, (block.y or 0) - pad, width + pad * 2, size.h + pad * 2,
            Blitbuffer.COLOR_WHITE)
    end
    widget:paintTo(bb, x, block.y or 0)
    widget:free()
end

--- 绘制圆角矩形；radius 为 0/nil 时退化为直角。
---@param bb userdata
---@param x number
---@param y number
---@param width number
---@param height number
---@param color any
---@param radius number|nil
local function paintRect(bb, x, y, width, height, color, radius)
    radius = math.max(0, math.floor(tonumber(radius) or 0))
    if radius > 0 then
        bb:paintRoundedRect(x, y, width, height, color, radius)
    else
        bb:paintRect(x, y, width, height, color)
    end
end

--- 将 widget 绘制到画布；越过任一画布边缘时裁剪，避免 blit 越界。
---@param bb userdata
---@param block table
---@param canvas_w number
---@param canvas_h number
local function paintWidget(bb, block, canvas_w, canvas_h)
    local widget = block.widget
    if not widget or type(widget.paintTo) ~= "function" then
        error("invalid lockscreen widget block")
    end
    local x = math.floor(block.x or 0)
    local y = math.floor(block.y or 0)
    if x >= canvas_w or y >= canvas_h then
        return
    end
    local size = widget.getSize and widget:getSize()
    if not size then
        local ok, err = pcall(widget.paintTo, widget, bb, math.max(0, x), math.max(0, y))
        if not ok then
            error(err)
        end
        return
    end
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
        local ok, err = pcall(widget.paintTo, widget, bb, x, y)
        if not ok then
            error(err)
        end
        return
    end
    local tmp = Blitbuffer.new(ww, wh, Blitbuffer.TYPE_BB8)
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

--- 分发非文本图形块：线、柱、卡片、点和离屏 widget。
--- 封面 / 进度条不再走 DSL；主体通过 kind=widget 复用 ui.components。
---@param bb userdata 目标 Blitbuffer
---@param block table 图形块描述
---@param w number 输出宽度
---@param h number 输出高度
local function paintShape(bb, block, w, h)
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
    elseif block.kind == "line" then
        -- 折线段：Bresenham 1px（stroke>1 时画平行粗线）
        local x1 = math.floor(block.x1 or x)
        local y1 = math.floor(block.y1 or y)
        local x2 = math.floor(block.x2 or x1)
        local y2 = math.floor(block.y2 or y1)
        local color = block.color or Blitbuffer.COLOR_BLACK
        local stroke = math.max(1, math.floor(tonumber(block.stroke) or 1))
        local dx = math.abs(x2 - x1)
        local dy = math.abs(y2 - y1)
        local sx = x1 < x2 and 1 or -1
        local sy = y1 < y2 and 1 or -1
        local err = dx - dy
        while true do
            if stroke <= 1 then
                bb:paintRect(x1, y1, 1, 1, color)
            else
                local half = math.floor(stroke / 2)
                bb:paintRect(x1 - half, y1 - half, stroke, stroke, color)
            end
            if x1 == x2 and y1 == y2 then
                break
            end
            local e2 = err * 2
            if e2 > -dy then
                err = err - dy
                x1 = x1 + sx
            end
            if e2 < dx then
                err = err + dx
                y1 = y1 + sy
            end
        end
    elseif block.kind == "dot" then
        local size = math.max(1, math.floor(tonumber(block.size) or 4))
        paintRect(bb, x, y, size, size, block.color or Blitbuffer.COLOR_BLACK, 0)
    elseif block.kind == "widget" then
        paintWidget(bb, block, w, h)
    end
end

--- 释放主体创建的离屏 widget，避免封面解码缓冲和容器留在内存中。
---@param blocks table[]
local function freeWidgets(blocks)
    local freed = {}
    for _, block in ipairs(blocks or {}) do
        local widget = block.widget
        if widget and not freed[widget] and type(widget.free) == "function" then
            freed[widget] = true
            pcall(widget.free, widget)
        end
    end
end

--- 生成 PNG，成功后原子替换。
--- 原子替换保证 KOReader 不会读到半张 compose.png。
---@param path string
---@param background string|nil
---@param blocks table[]
---@return boolean, any
function M.write(path, background, blocks)
    Paths.ensureScreensaverDir()
    local w, h = Layout.portraitSize()
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    local ok, err = pcall(function()
        local bg_ok, bg_err = paintBackground(bb, background, w, h)
        if not bg_ok then
            error(bg_err)
        end
        for _, block in ipairs(blocks) do
            if block.kind then
                paintShape(bb, block, w, h)
            else
                paintText(bb, block, w)
            end
        end
        local tmp = path .. ".part"
        bb:writePNG(tmp)
        if not os.rename(tmp, path) then
            os.remove(tmp)
            error("rename failed")
        end
    end)
    freeWidgets(blocks)
    bb:free()
    if not ok then
        logger.warn("Book lockscreen render failed:", err)
    end
    return ok, err
end

return M
