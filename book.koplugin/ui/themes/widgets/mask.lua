--[[--
主题遮罩：每 4 像素一点的网状压暗，墨水屏上接近半透明。
设置 ui.mesh_mask 关闭时不画；吞点击由 Modal 负责，不受影响。

  Mask:new{ dimen = Geom:new{ w = w, h = h } }

@module koplugin.book.ui.themes.widgets.mask
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local MoonSettings = require("utils.settings")
local Widget = require("ui/widget/widget")

---@class BookThemeMask : Widget
local Mask = Widget:extend{}

function Mask:paintTo(bb, x, y)
    if not MoonSettings.get("ui").mesh_mask then return end
    -- 夜间模式整屏反色，画白点才显示为黑点；画黑点会把底下提亮成一片灰。
    -- 每 4 像素一点：1px 棋盘在 Oasis 一类 300ppi 上会被波形糊成灰雾。
    local step = 4
    local dot = Device.screen.night_mode and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    for dy = 0, self.dimen.h - 1 do
        for dx = dy % step, self.dimen.w - 1, step do
            bb:setPixel(x + dx, y + dy, dot)
        end
    end
end

return Mask
