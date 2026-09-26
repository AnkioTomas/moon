--[[--
Widget 离屏绘制与 PNG 原子写入。借用 Widget，不释放调用方资源。
@module koplugin.book.ui.render
--]]
local Blitbuffer = require("ffi/blitbuffer")
local Render = {}

--- 将 widget 绘制到画布；越过任一画布边缘时裁剪，避免 blit 越界。
---@param bb BlitBuffer 用于绘制的 Blitbuffer 画布
---@param block table 包含 widget 与目标 x/y 坐标的绘制块
---@param canvas_w number 目标画布宽度，单位像素
---@param canvas_h number 目标画布高度，单位像素
function Render.paintWidget(bb, block, canvas_w, canvas_h)
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

--- 画布及临时文件归本次调用；失败保留原文件。
---@param path string 图片或书籍的本地文件路径
---@param width number 目标宽度，单位像素
---@param height number 目标高度，单位像素
---@param paint fun(bb: BlitBuffer)
---@return boolean, any
function Render.write(path, width, height, paint)
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
        bb = Blitbuffer.new(width, height, Blitbuffer.TYPE_BBRGB32)
        bb:fill(Blitbuffer.COLOR_WHITE)
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

return Render
