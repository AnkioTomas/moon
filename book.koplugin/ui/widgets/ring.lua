--[[--
活动环：同心圆环，从正上方顺时针填充，轨道用进度条轨道色。无环弧原语，逐像素按覆盖率灰阶抗锯齿。

  Ring:new{ size = 96, rings = { { fraction = 0.6 }, { fraction = 1 } } }   -- 外圈在前

@module koplugin.book.ui.widgets.ring
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")
local Theme = require("ui.themes")

---@class BookRing : Widget
---@field size number 物理像素直径
---@field rings { fraction: number }[] 外圈在前，fraction 0..1（超过 1 按满）
---@field thickness number|nil 物理像素环宽
local Ring = Widget:extend{
    size = nil,
    rings = nil,
    thickness = nil,
}

function Ring:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.size, h = self.size }
end

---@return table Geom
function Ring:getSize()
    return self.dimen
end

local function clamp01(v)
    return v < 0 and 0 or (v > 1 and 1 or v)
end

local function channel(track, ink, on, coverage)
    return math.floor(255 * (1 - coverage) + (track * (1 - on) + ink * on) * coverage + 0.5)
end

--- 画一圈：逐像素算覆盖率做灰阶抗锯齿（径向内外缘 + 弧段两端），底色按白处理。
---@param bb BlitBuffer
---@param cx number
---@param cy number
---@param radius number 环中线半径
---@param th number 环宽
---@param fraction number
---@param ink number 填充灰度
---@param track number 轨道灰度
local function paintRing(bb, cx, cy, radius, th, fraction, ink, track)
    local rgb = ink > 0xFF
    local ink_color = rgb and Theme.color(ink)
    local track_color = rgb and Theme.color(track)
    local ir, ig, ib, tr, tg, tb
    if rgb then
        ir, ig, ib = ink_color:getR(), ink_color:getG(), ink_color:getB()
        tr, tg, tb = track_color:getR(), track_color:getG(), track_color:getB()
    end
    local ro, ri = radius + th / 2, radius - th / 2
    local end_a = 2 * math.pi * math.min(1, math.max(0, fraction))
    local full = fraction >= 1
    local reach_o, reach_i = ro + 1, math.max(0, ri - 1)
    for dy = -math.ceil(reach_o), math.ceil(reach_o) do
        local py = dy + 0.5
        local xo = math.sqrt(math.max(0, reach_o * reach_o - py * py))
        local xi = math.sqrt(math.max(0, reach_i * reach_i - py * py))
        local x0, x1 = math.floor(xo), math.floor(xi)
        for side = 0, 1 do
            for ix = x1, x0 do
                local dx = side == 0 and -ix - 0.5 or ix + 0.5
                local d = math.sqrt(dx * dx + py * py)
                local cov = clamp01(ro - d + 0.5) * clamp01(d - ri + 0.5)
                if cov > 0 then
                    local a = math.atan2(dx, -py)
                    if a < 0 then a = a + 2 * math.pi end
                    local on = full and 1
                        or clamp01(0.5 + (end_a - a) * d) * clamp01(0.5 + a * d)
                    local color
                    if rgb then
                        color = Blitbuffer.ColorRGB32(channel(tr, ir, on, cov),
                            channel(tg, ig, on, cov), channel(tb, ib, on, cov), 0xFF)
                    else
                        local v = track * (1 - on) + ink * on
                        v = 255 * (1 - cov) + v * cov
                        color = Blitbuffer.Color8(math.floor(v + 0.5))
                    end
                    bb:setPixel(cx + math.floor(dx), cy + math.floor(py), color)
                end
            end
        end
    end
end

---@param bb BlitBuffer
---@param x number
---@param y number
function Ring:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local t = Theme.current()
    local th = self.thickness or math.max(3, math.floor(self.size / (#self.rings * 2 + 8)))
    local gap = math.max(3, math.floor(th / 2))
    local ink, track = t.progress.fill, t.progress.track
    local c = math.floor(self.size / 2)
    local radius = c - math.ceil(th / 2)
    for _idx, ring in ipairs(self.rings) do
        paintRing(bb, x + c, y + c, radius, th, ring.fraction or 0, ink, track)
        radius = radius - th - gap
    end
end

return Ring
