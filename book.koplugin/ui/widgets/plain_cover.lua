--[[--
无封面时的生成封面：按书名取色的纯色底 + 内框 + 竖排书名（最多四字）+ 底部作者。

  +------------+
  | +--------+ |
  | |   三   | |
  | |   国   | |
  | |   演   | |
  | |   义   | |
  | |  罗贯中 | |
  | +--------+ |
  +------------+

  PlainCover:new{ title = "三国演义", author = "罗贯中", width = w, height = h }

同一书名永远同色。和真实封面图一样不随夜间模式反色。

@module koplugin.book.ui.widgets.plain_cover
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local Widget = require("ui/widget/widget")
local Theme = require("ui.themes")
local util = require("util")

local PALETTE = {
    { 0x8B, 0x2E, 0x3A }, -- 绛红
    { 0x3E, 0x5A, 0x85 }, -- 靛蓝
    { 0x2B, 0x2B, 0x2B }, -- 墨黑
    { 0x5F, 0x6B, 0x70 }, -- 青灰
    { 0x6B, 0x42, 0x26 }, -- 赭石
    { 0xA0, 0x38, 0x6E }, -- 品红
    { 0x2E, 0x6B, 0x4F }, -- 松绿
    { 0xB8, 0x6A, 0x22 }, -- 琥珀
}
local MAX_CHARS = 4
-- 竖排字距 / 字号。TextWidget 的行高带字体上下留白（约 1.4 倍），不能拿来叠字。
local PITCH = 1.2

---@class BookPlainCover : Widget
---@field title string
---@field author string
---@field width number 物理像素
---@field height number 物理像素
---@field author_widget table|nil
---@field chars table[]
---@field bg table ColorRGB32
local PlainCover = Widget:extend{
    title = "",
    author = "",
    width = 0,
    height = 0,
}

--- 按物理像素取字面：Font:getFace 会再乘一次 DPI，这里先除掉。
---@param px number
---@return table
local function faceAt(px)
    return Font:getFace("cfont", math.max(6, math.floor(px * 100 / Device.screen:scaleBySize(100))))
end

---@param s string
---@return number 1..#PALETTE
local function colorIndex(s)
    local h = 0
    for i = 1, #s do
        h = (h * 31 + s:byte(i)) % 2147483647
    end
    return h % #PALETTE + 1
end

function PlainCover:init()
    local w, h = self.width, self.height
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
    self.margin = math.max(2, math.floor(w * 0.06 + 0.5))
    self.line = math.max(1, math.floor(w / 120 + 0.5))
    local rgb = PALETTE[colorIndex(self.title)]
    -- 彩屏上这块纯色底同样会被冲淡，开彩色时补饱和；灰度屏保持原色板。
    local Screen = Device.screen
    if Screen.isColorEnabled and Screen:isColorEnabled() then
        local packed = Theme.vivid(rgb[1] * 0x10000 + rgb[2] * 0x100 + rgb[3])
        rgb = { math.floor(packed / 0x10000), math.floor(packed / 0x100) % 0x100, packed % 0x100 }
    end
    self.bg = Blitbuffer.ColorRGB32(rgb[1], rgb[2], rgb[3], 0xFF)

    local inner_w = w - self.margin * 2
    local author_px = math.floor(w * 0.08 + 0.5)
    self.author_widget = self.author ~= "" and TextWidget:new{
        text = self.author,
        face = faceAt(author_px),
        max_width = inner_w - self.margin * 2,
    } or nil
    -- 字号按四字排满定死，两三字的书名与四字同字号。
    local title_area = h - self.margin * 4 - author_px * 3
    local title_px = math.floor(math.min(w * 0.2, title_area / MAX_CHARS / PITCH))
    self.pitch = math.floor(title_px * PITCH)
    local face = faceAt(title_px)
    self.chars = {}
    for _idx, ch in ipairs(util.splitToChars((self.title:gsub("%s", "")))) do
        if #self.chars == MAX_CHARS then break end
        self.chars[#self.chars + 1] = TextWidget:new{ text = ch, face = face }
    end
end

---@param bb BlitBuffer
---@param x number
---@param y number
function PlainCover:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h, m = self.width, self.height, self.margin
    local night = Device.screen.night_mode
    local ink = night and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    bb:paintRectRGB32(x, y, w, h, night and self.bg:invert() or self.bg)
    bb:paintBorder(x + m, y + m, w - m * 2, h - m * 2, self.line, ink)

    local bottom = y + h - m
    if self.author_widget then
        local size = self.author_widget:getSize()
        self.author_widget.fgcolor = ink
        bottom = bottom - size.h * 2
        self.author_widget:paintTo(bb, x + math.floor((w - size.w) / 2), bottom + math.floor(size.h / 2))
    end
    local pitch = self.pitch
    local cy = y + m + math.floor((bottom - y - m - pitch * #self.chars) / 2)
    for _idx, ch in ipairs(self.chars) do
        local size = ch:getSize()
        ch.fgcolor = ink
        ch:paintTo(bb, x + math.floor((w - size.w) / 2), cy + math.floor((pitch - size.h) / 2))
        cy = cy + pitch
    end
end

function PlainCover:free()
    for _idx, ch in ipairs(self.chars) do ch:free() end
    if self.author_widget then self.author_widget:free() end
end

return PlainCover
