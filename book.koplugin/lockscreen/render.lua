--[[--
锁屏离屏渲染：背景图片 + 文本块写为 PNG。

@module koplugin.book.lockscreen.render
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local ImageWidget = require("ui/widget/imagewidget")
local logger = require("logger")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Paths = require("utils.paths")

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

---@return number, number
function M.size()
    local w, h = Device.screen:getWidth(), Device.screen:getHeight()
    if w > h then
        return h, w
    end
    return w, h
end

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
    local probe = ImageWidget:new{ file = path, scale_factor = 1, alpha = true }
    local ok_size, iw, ih = pcall(function()
        probe:getSize() -- ImageWidget getters are empty until the first render.
        return probe:getOriginalWidth(), probe:getOriginalHeight()
    end)
    probe:free()
    if not ok_size or not iw or not ih or iw <= 0 or ih <= 0 then
        return false, "cannot decode background: " .. tostring(path)
    end
    local image = ImageWidget:new{
        file = path,
        width = w,
        height = h,
        scale_factor = math.max(w / iw, h / ih),
        alpha = true,
    }
    local ok, err = pcall(image.paintTo, image, bb, 0, 0)
    image:free()
    if not ok then
        return false, err
    end
    return true
end

---@param bb userdata 目标 Blitbuffer
---@param block table 文本块描述
---@param w number 输出宽度
---@return number 实际文本高度
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
    return size.h
end

---@param bb userdata 目标 Blitbuffer
---@param block table 图形块描述
---@param w number 输出宽度
local function paintShape(bb, block, w)
    local x = block.x or math.floor(w * 0.08)
    local width = block.width or (w - x * 2)
    if block.kind == "rule" then
        bb:paintRect(x, block.y or 0, width, block.height or 2,
            block.color or Blitbuffer.COLOR_BLACK)
    elseif block.kind == "bar" then
        local height = block.height or 12
        bb:paintRect(x, block.y or 0, width, height, Blitbuffer.COLOR_GRAY_E)
        bb:paintRect(x, block.y or 0, math.floor(width * math.max(0, math.min(1, block.value or 0))), height,
            block.color or Blitbuffer.COLOR_BLACK)
    elseif block.kind == "panel" then
        bb:paintRect(x, block.y or 0, width, block.height or 1,
            block.color or Blitbuffer.COLOR_WHITE)
    elseif block.kind == "vbar" then
        local height = block.height or 1
        local filled = math.floor(height * math.max(0, math.min(1, block.value or 0)))
        bb:paintRect(x, (block.y or 0) + height - filled, width, filled,
            block.color or Blitbuffer.COLOR_BLACK)
    end
end

--- 生成 PNG，成功后原子替换。
---@param path string
---@param background string|nil
---@param blocks table[]
---@return boolean, any
function M.write(path, background, blocks)
    Paths.ensureScreensaverDir()
    local w, h = M.size()
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    local ok, err = pcall(function()
        local bg_ok, bg_err = paintBackground(bb, background, w, h)
        if not bg_ok then
            error(bg_err)
        end
        for _, block in ipairs(blocks) do
            if block.kind then
                paintShape(bb, block, w)
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
    bb:free()
    if not ok then
        logger.warn("Book lockscreen render failed:", err)
    end
    return ok, err
end

return M
