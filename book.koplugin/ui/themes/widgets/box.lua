--[[--
主题表面：一个子件 + 底色 / 边框 / 圆角 / 右下阴影，全部自绘，不走 FrameContainer。

  +--------------+
  |    child     |▓   ← shadow 偏移，计入尺寸，不挤占 width/height
  +--------------+▓
   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓

  Box:new{ style = theme.card, width = w, height = h, padding = p, child }

style 取 card / raised / dialog 这类表面令牌（bg/border/border_color/radius/shadow/shadow_color，
逻辑像素）；缺 bg 不填底。width/height/padding 是物理像素，不给宽高时按子件加内边距撑开，
子件在框内居中。圆角大于 0 时，子件画完后把四角圆外的像素还回去，直角图不会冒出框。
尺寸在 init 定死：内容变化的调用方重建 Box。

@module koplugin.book.ui.themes.widgets.box
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Theme = require("ui.themes")

---@class BookThemeBox : WidgetContainer
---@field style table 表面令牌
---@field padding number 物理像素内边距
---@field width number|nil 物理像素外框宽（不含阴影）
---@field height number|nil 物理像素外框高（不含阴影）
---@field box_w number 实际外框宽（init 算定，不含阴影）
---@field box_h number 实际外框高（init 算定，不含阴影）
local Box = WidgetContainer:extend{
    style = nil,
    padding = 0,
    width = nil,
    height = nil,
}

function Box:init()
    local size = self[1] and self[1]:getSize() or { w = 0, h = 0 }
    self.box_w = self.width or size.w + self.padding * 2
    self.box_h = self.height or size.h + self.padding * 2
    self.shadow = Theme.px(self.style.shadow or 0)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.box_w + self.shadow, h = self.box_h + self.shadow }
end

---@return table Geom
function Box:getSize()
    return self.dimen
end

--- 圆角方块的角外像素。圆心在 (r, r)，和 paintRoundedRect 的圆角同一套。
---@param i number 距该角外侧的横向像素
---@param j number 距该角外侧的纵向像素
---@param r number
---@return boolean
local function outsideCorner(i, j, r)
    local dx, dy = r - i, r - j
    return dx * dx + dy * dy > r * r
end

--- 子件绘制前抄下四角圆外的颜色，画完写回。直角位图就停在圆角里面。
---@param bb BlitBuffer
---@param x number
---@param y number
---@param w number
---@param h number
---@param r number
---@return table[]|nil
local function snapshotCorners(bb, x, y, w, h, r)
    if not bb.getPixel or not bb.getWidth then return nil end
    local bw, bh = bb:getWidth(), bb:getHeight()
    local saved = {}
    local function take(px, py)
        if px < 0 or py < 0 or px >= bw or py >= bh then return end
        local color = bb:getPixel(px, py)
        saved[#saved + 1] = { px, py, color:getColorRGB32() }
    end
    for j = 0, r - 1 do
        for i = 0, r - 1 do
            if outsideCorner(i, j, r) then
                take(x + i, y + j)
                take(x + w - 1 - i, y + j)
                take(x + i, y + h - 1 - j)
                take(x + w - 1 - i, y + h - 1 - j)
            end
        end
    end
    return saved
end

---@param bb BlitBuffer 目标画布
---@param x number
---@param y number
function Box:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local s = self.style
    local w, h = self.box_w, self.box_h
    -- paintBorder 不夹半径，这里统一夹到短边一半，radius=999 即胶囊。
    local r = math.min(Theme.px(s.radius or 0), math.floor(math.min(w, h) / 2))
    if self.shadow > 0 then
        bb:paintRoundedRect(x + self.shadow, y + self.shadow, w, h, Blitbuffer.Color8(s.shadow_color), r)
    end
    if s.bg then
        bb:paintRoundedRect(x, y, w, h, Blitbuffer.Color8(s.bg), r)
    end
    local border = Theme.px(s.border or 0)
    if border > 0 then
        -- 只有边框收 anti_alias（paintRoundedRect 不收）：和 FrameContainer 一样靠它盖住底色的锯齿。
        bb:paintBorder(x, y, w, h, border, Blitbuffer.Color8(s.border_color), r, true)
    end
    local child = self[1]
    if not child then return end
    local saved = r > 0 and snapshotCorners(bb, x, y, w, h, r) or nil
    local cs = child:getSize()
    child:paintTo(bb, x + math.floor((w - cs.w) / 2), y + math.floor((h - cs.h) / 2))
    if not saved then return end
    for _idx, pixel in ipairs(saved) do
        bb:setPixel(pixel[1], pixel[2], pixel[3])
    end
end

return Box
