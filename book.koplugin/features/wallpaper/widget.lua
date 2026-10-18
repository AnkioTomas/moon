--[[--
壁纸底座：先铺壁纸，再按原坐标画子件。

给桌面外壳用——主题 Box 只有一个子件槽，壁纸不能当兄弟件插进去，只能把它
垫在内容层下面。子件拿到的坐标与原先完全一致（顶栏 / 底栏的 overlap_offset
由内容层的 OverlapGroup 自己处理，这里原样转发）。

@module koplugin.book.features.wallpaper.widget
--]]

local Geom = require("ui/geometry")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Wallpaper = require("features.wallpaper")

---@class BookWallpaperBox : WidgetContainer
---@field scope string desktop / dialog
---@field width number 物理像素
---@field height number 物理像素
local WallpaperBox = WidgetContainer:extend{
    scope = "desktop",
    width = 0,
    height = 0,
}

function WallpaperBox:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

---@param bb BlitBuffer
---@param x number
---@param y number
function WallpaperBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    Wallpaper.paintTo(bb, x, y, self.width, self.height, self.scope)
    -- 顶栏 / 底栏不跟着透的那条补回页面底色。
    Wallpaper.paintBars(bb, x, y, self.width, self.height)
    if self[1] then self[1]:paintTo(bb, x, y) end
end

return WallpaperBox
