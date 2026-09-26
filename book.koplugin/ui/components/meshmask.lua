--[[--
墨水屏网状遮罩：单像素黑白交错，模拟半透明压暗。
显示设置 mesh_mask 关闭时不画；吞点击由调用方容器负责，不受影响。

用法：
  MeshMask.widget{ width = w, height = h }
  MeshMask.widget{ dimen = Geom:new{ w = w, h = h } }

@module koplugin.book.ui.components.meshmask
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local MoonSettings = require("utils.settings")
local Widget = require("ui/widget/widget")

---@class BookMeshMask : Widget
---@field dimen table
local MeshMaskWidget = Widget:extend{}

function MeshMaskWidget:getSize()
    return self.dimen
end

function MeshMaskWidget:paintTo(bb, x, y)
    if not MoonSettings.get("display").mesh_mask then return end
    local w, h = self.dimen.w, self.dimen.h
    -- 夜间模式整屏反色（硬件反色或 bb 反相），画白点才显示为黑点；画黑点会把底下提亮成一片灰。
    local dot = Device.screen.night_mode and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    -- 单像素交错：墨水屏上接近半透明，又不会糊成大色块。
    for dy = 0, h - 1 do
        for dx = dy % 2, w - 1, 2 do
            bb:setPixel(x + dx, y + dy, dot)
        end
    end
end

---@class BookMeshMaskFactory
local MeshMask = {}

--- 构建网状遮罩。
---@param opts { width?: number, height?: number, dimen?: table }|nil
---@return table
function MeshMask.widget(opts)
    opts = opts or {}
    local dimen = opts.dimen
    if not dimen then
        dimen = Geom:new{
            w = math.max(1, math.floor(tonumber(opts.width) or 1)),
            h = math.max(1, math.floor(tonumber(opts.height) or 1)),
        }
    end
    return MeshMaskWidget:new{ dimen = dimen }
end

return MeshMask
