--[[--
主题进度条：轨道 + 填充 + 可选边框，自绘，不用 ProgressWidget。

  [██████········]   percent 0–100

  local bar = Progress:new{ width = w, percent = 30 }   -- height 缺省取 progress.height
  bar:setPercent(60)                                    -- 调用方负责 setDirty

@module koplugin.book.ui.themes.widgets.progress
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")
local Theme = require("ui.themes.init")

---@class BookThemeProgress : Widget
---@field width number 物理像素
---@field height number|nil 物理像素
---@field percent number 0–100
local Progress = Widget:extend{
    width = nil,
    height = nil,
    percent = 0,
}

function Progress:init()
    self.style = Theme.current().progress
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height or Theme.px(self.style.height) }
    self:setPercent(self.percent)
end

---@return table Geom
function Progress:getSize()
    return self.dimen
end

--- 更新进度，夹到 0–100。
---@param value number|nil nil 按 0
function Progress:setPercent(value)
    self.percent = math.max(0, math.min(100, value or 0))
end

---@param bb BlitBuffer 目标画布
---@param x number
---@param y number
function Progress:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local s = self.style
    local w, h = self.dimen.w, self.dimen.h
    local r = math.min(Theme.px(s.radius), math.floor(h / 2))
    local border = Theme.px(s.border)
    bb:paintRoundedRect(x, y, w, h, Blitbuffer.Color8(s.track), r)
    local fill_w = math.floor((w - border * 2) * self.percent / 100 + 0.5)
    if fill_w > 0 then
        bb:paintRoundedRect(x + border, y + border, fill_w, h - border * 2,
            Blitbuffer.Color8(s.fill), math.max(0, r - border))
    end
    if border > 0 then
        bb:paintBorder(x, y, w, h, border, Blitbuffer.Color8(s.border_color), r)
    end
end

return Progress
