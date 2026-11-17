--[[--
无封面时的生成封面（风格 color：按书名取色的纯色底；plain：白底黑字）：纯色底 + 内框 + 竖排书名（最多四字）+ 底部作者。

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
---@field style string|nil "color" 按书名取色（默认）；"plain" 白底黑字
---@field truncate boolean|nil 书名超过 MAX_CHARS 字时截断（默认是）；否则满四字转到左边一列
---@field width number 物理像素
---@field height number 物理像素
---@field author_widget table|nil
---@field columns table[][] 竖排列，第一列在最右
---@field bg table ColorRGB32
local PlainCover = Widget:extend{
    title = "",
    author = "",
    style = "color",
    truncate = true,
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
    local rgb = self.style == "plain" and { 0xFF, 0xFF, 0xFF } or PALETTE[colorIndex(self.title)]
    -- 彩屏上这块纯色底同样会被冲淡，开彩色时补饱和；灰度屏保持原色板。
    local Screen = Device.screen
    if self.style ~= "plain" and Screen.isColorEnabled and Screen:isColorEnabled() then
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
    local all = util.splitToChars((self.title:gsub("%s", "")))
    local title_px = math.floor(math.min(w * 0.2, title_area / MAX_CHARS / PITCH))
    self.pitch = math.floor(title_px * PITCH)
    local face = faceAt(title_px)
    -- 不截断时按竖排习惯满列后转到左边一列，列数受内框宽度限制，放不下的才丢弃。
    local cols = self.truncate and 1 or math.max(1, math.min(math.ceil(#all / MAX_CHARS), math.floor(inner_w / self.pitch)))
    self.columns = {}
    for idx, ch in ipairs(all) do
        local col = math.ceil(idx / MAX_CHARS)
        if col > cols then break end
        self.columns[col] = self.columns[col] or {}
        table.insert(self.columns[col], TextWidget:new{ text = ch, face = face })
    end
end

---@param bb BlitBuffer
---@param x number
---@param y number
function PlainCover:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h, m = self.width, self.height, self.margin
    local night = Device.screen.night_mode and true or false
    local plain = self.style == "plain"
    local ink = (night ~= plain) and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
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
    local ncol = #self.columns
    for ci, col in ipairs(self.columns) do
        -- 第一列在最右。
        local cx = x + math.floor(w / 2 + (ncol / 2 - ci + 0.5) * pitch)
        local cy = y + m + math.floor((bottom - y - m - pitch * #col) / 2)
        for _idx, ch in ipairs(col) do
            local size = ch:getSize()
            ch.fgcolor = ink
            ch:paintTo(bb, cx - math.floor(size.w / 2), cy + math.floor((pitch - size.h) / 2))
            cy = cy + pitch
        end
    end
end

function PlainCover:free()
    for _idx, col in ipairs(self.columns) do
        for _jdx, ch in ipairs(col) do ch:free() end
    end
    if self.author_widget then self.author_widget:free() end
end

return PlainCover
