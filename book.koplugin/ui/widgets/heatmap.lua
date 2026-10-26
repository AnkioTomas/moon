--[[--
热力图：一列一周、一行一天的方格，深浅表示当天阅读时长级别。

  Heatmap:new{ cols = Calc.heatmap(...).cols, width = w }   -- 方格边长按宽度自适应

灰阶 5 级（0 = 空），墨水屏黑白也分得出。

@module koplugin.book.ui.widgets.heatmap
--]]

local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")
local Theme = require("ui.themes")

---@class BookHeatmap : Widget
---@field cols table[] cols[c][r] = { level } | false
---@field width number 物理像素
local Heatmap = Widget:extend{
    cols = nil,
    width = nil,
}

local SHADES = { 0xEE, 0xC8, 0x98, 0x58, 0x00 }
local GAP = 1

function Heatmap:init()
    local n = #self.cols
    self.cell = math.max(2, math.floor((self.width - GAP * (n - 1)) / n))
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = n * self.cell + (n - 1) * GAP,
        h = 7 * self.cell + 6 * GAP,
    }
end

---@return table Geom
function Heatmap:getSize()
    return self.dimen
end

---@param bb BlitBuffer
---@param x number
---@param y number
function Heatmap:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local fill = Theme.current().progress.fill
    local shades = SHADES
    if fill > 0xFF then
        shades = {}
        for level = 0, 4 do shades[level + 1] = Theme.mix(SHADES[1], fill, level / 4) end
    end
    for c, col in ipairs(self.cols) do
        for r, cell in ipairs(col) do
            if cell then
                local value = shades[cell.level + 1]
                local paint = value > 0xFF and bb.paintRectRGB32 or bb.paintRect
                paint(bb,
                    x + (c - 1) * (self.cell + GAP), y + (r - 1) * (self.cell + GAP),
                    self.cell, self.cell, Theme.color(value)
                )
            end
        end
    end
end

return Heatmap
