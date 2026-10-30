--[[--
主题表面：一个子件 + 底色 / 边框 / 圆角 / 右下阴影，全部自绘，不走 FrameContainer。

  +--------------+
  |    child     |▓   ← shadow 偏移，计入尺寸，不挤占 width/height
  +--------------+▓
   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓

  Box:new{ style = theme.card, width = w, height = h, padding = p, child }

style 取 card / raised / dialog 这类表面令牌（bg/border/border_color/radius/shadow/shadow_color，
逻辑像素）；缺 bg 不填底。width/height/padding 是物理像素，不给宽高时按子件加内边距撑开，
子件在框内居中。圆角大于 0 时，先抄角外底色（在画阴影之前），子件画完再还回去，
直角图不会冒出框；阴影偏右下，若画完阴影再抄，底角会还原成阴影色、看起来像直角。
尺寸在 init 定死：内容变化的调用方重建 Box。

@module koplugin.book.ui.themes.widgets.box
--]]

local Geom = require("ui/geometry")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Theme = require("ui.themes")

---@class BookThemeBox : WidgetContainer
---@field style table 表面令牌
---@field padding number 物理像素内边距
---@field width number|nil 物理像素外框宽（不含阴影）
---@field height number|nil 物理像素外框高（不含阴影）
---@field bg_alpha number|nil 底色不透明度百分比（缺省 100）；<100 时底色按比例叠在下层内容上，底色须为白
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
        -- 真机 getPixel 返回 Color*；灰度桩 / 部分路径会直接给 number。
        if type(color) == "table" and color.getColorRGB32 then
            color = color:getColorRGB32()
        end
        saved[#saved + 1] = { px, py, color }
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
    -- 角外底色必须在画阴影之前抄：阴影偏右下，画完再抄会把底角还原成阴影色，
    -- 封面底边看起来像直角（柔和 raised 阴影 + 圆角封面就是这个坑）。
    local saved = r > 0 and snapshotCorners(bb, x, y, w, h, r) or nil
    if self.shadow > 0 then
        bb:paintRoundedRect(x + self.shadow, y + self.shadow, w, h, Theme.color(s.shadow_color), r)
    end
    if s.bg and self.bg_alpha and self.bg_alpha < 100 then
        -- 白底按比例向白提亮即「白色 + 透明度」；直角提亮冒出的角外靠收尾还原。
        bb:lightenRect(x, y, w, h, self.bg_alpha / 100)
    elseif s.bg then
        local paint = s.bg > 0xFF and bb.paintRoundedRectRGB32 or bb.paintRoundedRect
        paint(bb, x, y, w, h, Theme.color(s.bg), r)
    end
    local border = Theme.px(s.border or 0)
    if border > 0 then
        -- 只有边框收 anti_alias（paintRoundedRect 不收）：和 FrameContainer 一样靠它盖住底色的锯齿，
        -- 也和它一样听 KOReader「界面抗锯齿」设置。
        local paint = s.border_color > 0xFF and bb.paintBorderRGB32 or bb.paintBorder
        paint(bb, x, y, w, h, border, Theme.color(s.border_color), r,
            G_reader_settings:nilOrTrue("anti_alias_ui"))
    end
    local child = self[1]
    if not child then
        if saved then
            for _idx, pixel in ipairs(saved) do bb:setPixel(pixel[1], pixel[2], pixel[3]) end
        end
        return
    end
    local cs = child:getSize()
    child:paintTo(bb, x + math.floor((w - cs.w) / 2), y + math.floor((h - cs.h) / 2))
    if not saved then return end
    for _idx, pixel in ipairs(saved) do
        bb:setPixel(pixel[1], pixel[2], pixel[3])
    end
end

return Box
