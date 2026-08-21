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
---@param block table 本地图片块
local function paintImage(bb, block)
    local path = block.path
    local x = block.x or 0
    local y = block.y or 0
    local width = math.max(1, block.width or 1)
    local height = math.max(1, block.height or 1)
    if block.shadow then
        local s = block.shadow
        bb:paintRect(x + s, y + s, width, height, Blitbuffer.COLOR_GRAY_9)
    end
    -- 精装衬底：letterbox 留边也像书壳，不露屏底
    bb:paintRect(x, y, width, height, block.matte or Blitbuffer.COLOR_GRAY_4)
    if type(path) ~= "string" or path == "" then
        if block.border then
            bb:paintBorder(x, y, width, height, 1, Blitbuffer.COLOR_BLACK)
        end
        return
    end
    local probe = ImageWidget:new{ file = path, scale_factor = 1, alpha = true }
    local ok_size, iw, ih = pcall(function()
        probe:getSize()
        return probe:getOriginalWidth(), probe:getOriginalHeight()
    end)
    probe:free()
    if not ok_size or not iw or not ih or iw <= 0 or ih <= 0 then
        if block.border then
            bb:paintBorder(x, y, width, height, 1, Blitbuffer.COLOR_BLACK)
        end
        return
    end
    local pad = block.inset or 0
    local aw = math.max(1, width - pad * 2)
    local ah = math.max(1, height - pad * 2)
    local scale = math.min(aw / iw, ah / ih)
    local dw = math.max(1, math.floor(iw * scale))
    local dh = math.max(1, math.floor(ih * scale))
    local image = ImageWidget:new{
        file = path,
        width = dw,
        height = dh,
        scale_factor = scale,
        alpha = true,
    }
    local ox = x + pad + math.floor((aw - dw) / 2)
    local oy = y + pad + math.floor((ah - dh) / 2)
    local ok = pcall(image.paintTo, image, bb, ox, oy)
    image:free()
    if block.border then
        bb:paintBorder(x, y, width, height, 1, Blitbuffer.COLOR_BLACK)
    end
    if not ok then
        return
    end
end

--- 书脊：竖放 / 横放 / 斜靠 / 平躺。斜靠用逐行错位近似。
---@param bb userdata
---@param block table
local function paintSpine(bb, block)
    local x = block.x or 0
    local y = block.y or 0
    local width = math.max(1, block.width or 1)
    local height = math.max(1, block.height or 1)
    local color = block.color or Blitbuffer.COLOR_GRAY_5
    local pose = block.pose or "vertical"
    local lean_shift = 0
    local dir = 1

    if block.shadow then
        local s = block.shadow
        bb:paintRect(x + s, y + s, width, height, Blitbuffer.COLOR_GRAY_9)
    end

    if pose == "tilt" then
        local lean = block.lean or 0.12
        lean_shift = math.floor(height * lean)
        dir = block.dir == "left" and -1 or 1
        if lean_shift < 2 then
            bb:paintRect(x, y, width, height, color)
            lean_shift = 0
        else
            for row = 0, height - 1 do
                local dx = math.floor(dir * lean_shift * (1 - row / height))
                bb:paintRect(x + dx, y + row, width, 1, color)
            end
        end
    else
        bb:paintRect(x, y, width, height, color)
    end

    -- 左侧高光 + 右侧暗边：一点厚度感
    if width >= 6 and pose ~= "tilt" then
        bb:paintRect(x + 1, y + 1, 1, height - 2, Blitbuffer.COLOR_GRAY_B)
        bb:paintRect(x + width - 2, y + 1, 1, height - 2, Blitbuffer.COLOR_GRAY_3)
    end

    -- 书脊装饰线（上下各一条）
    if block.band and width >= 5 and height >= 24 then
        local band_y1 = y + math.floor(height * 0.12)
        local band_y2 = y + math.floor(height * 0.88)
        local bx = x + 2
        local bw = math.max(1, width - 4)
        bb:paintRect(bx, band_y1, bw, 1, Blitbuffer.COLOR_GRAY_E)
        bb:paintRect(bx, band_y2, bw, 1, Blitbuffer.COLOR_GRAY_E)
    end

    if lean_shift > 0 then
        local bx = dir < 0 and (x - lean_shift) or x
        bb:paintBorder(bx, y, width + lean_shift, height, 1, Blitbuffer.COLOR_BLACK)
    else
        bb:paintBorder(x, y, width, height, 1, Blitbuffer.COLOR_BLACK)
    end

    local label = block.label
    if type(label) == "string" and label ~= "" and width >= 12 and height >= 28 then
        local size = math.max(10, math.min(14, math.floor(width * 0.5)))
        if pose == "flat" or pose == "horizontal" then
            size = math.max(10, math.min(16, math.floor(height * 0.4)))
        end
        local pad = 2
        local widget = TextBoxWidget:new{
            text = label,
            face = Font:getFace("cfont", size),
            width = math.max(1, width - pad * 2),
            alignment = "center",
            fgcolor = Blitbuffer.COLOR_WHITE,
            bold = true,
        }
        local size_h = widget:getSize().h
        local ty = y + math.max(0, math.floor((height - size_h) / 2))
        widget:paintTo(bb, x + pad, ty)
        widget:free()
    end
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
    elseif block.kind == "image" then
        paintImage(bb, block)
    elseif block.kind == "spine" then
        paintSpine(bb, block)
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
