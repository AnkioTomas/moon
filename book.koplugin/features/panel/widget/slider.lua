--[[-- 灯光滑杆：Kindle 下拉面板那一排。

两端是方向图标（暗/亮、冷/暖），中间是圆头滑轨。没有百分比：
Kindle 亮度、暖色都是 0..24 档，按 0..100 显示再折回原生档，手指挪了数字在变、灯不动。

点两端图标加减一档，点轨道或拖动才跳到手指下的那一档。拖动时灯马上变；
电子墨水（screen.low_pan_rate）上滑轨重绘压到大约 3Hz，松手补最后一帧，
避免每颗触点都刷一次面板。

@module koplugin.book.features.panel.widget.slider
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local Icon = require("ui.themes.widgets.icon")
local Theme = require("ui.themes")

--- 拖动中两次重绘的最小间隔。和 KOReader 前光面板一样：3Hz，没跟上的那帧 75ms 后补。
local DRAG_HZ = 3
local DRAG_TRAIL = 0.075

local ENDS = {
    brightness = { "brightness_low", "brightness_high" },
    warmth = { "ac_unit", "wb_incandescent" },
}

--- 灯光滑杆行。
---@class BookQuickPanelSliderRow : InputContainer
---@field width number
---@field height number
---@field kind "brightness"|"warmth"
---@field min number 硬件最小档
---@field max number 硬件最大档
---@field floor number 手势最低档。亮度跳过 0（关灯是前光开关的事）
---@field value number 当前档，灯关着时可以低于 floor
---@field on_level fun(kind: string, fraction: number): boolean|nil
---@field show_parent table
---@field bar_x number
---@field bar_w number
---@field track_h number
---@field thumb_r number
local SliderRow = InputContainer:extend{}

---@param n number
---@return number
local function clamp01(n)
    if n < 0 then return 0 end
    if n > 1 then return 1 end
    return n
end

---@param token number
---@return boolean
local function wide(token)
    return token > 0xFF
end

--- 初始化手势区、两端图标和滑轨占位。
---@param self BookQuickPanelSliderRow
function SliderRow:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local range = self.dimen
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = range } },
        Pan = { GestureRange:new{ ges = "pan", range = range } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
        Hold = { GestureRange:new{ ges = "hold", range = range } },
        HoldPan = { GestureRange:new{ ges = "hold_pan", range = range } },
        HoldRelease = { GestureRange:new{ ges = "hold_release", range = range } },
    }
    local t = Theme.current()
    local icon = Theme.px(t.control.icon)
    local gap = Theme.px(t.space.sm)
    self.bar_x = icon + gap
    self.bar_w = math.max(0, self.width - icon * 2 - gap * 2)
    self.track_h = Theme.px(10)
    self.thumb_r = Theme.px(8)
    local ink = Theme.color(t.color.ink)
    local ends = ENDS[self.kind]
    -- 图标方盒比行矮。不把方盒在行高里居中的话，图标贴在行顶，轨道画在行中间。
    local function endIcon(name)
        return CenterContainer:new{
            dimen = Geom:new{ w = icon, h = self.height },
            Icon.widget{ name = name, size = t.control.icon, color = ink },
        }
    end
    self._flush = function()
        self._queued = false
        self._last_paint = time.now()
        UIManager:setDirty(self.show_parent, "ui", self.dimen)
    end
    self[1] = HorizontalGroup:new{
        align = "center",
        endIcon(ends[1]),
        HorizontalSpan:new{ width = gap },
        HorizontalSpan:new{ width = self.bar_w },
        HorizontalSpan:new{ width = gap },
        endIcon(ends[2]),
    }
end

--- 电子墨水拖动时限制重绘；模拟器每次档位变化都画。
---@return boolean
function SliderRow:paintDue()
    local screen = require("device").screen
    if not (screen and screen.low_pan_rate) then return true end
    if not self._last_paint then return true end
    return time.now() - self._last_paint >= time.s(1 / DRAG_HZ)
end

---@param self BookQuickPanelSliderRow
function SliderRow:cancelPaint()
    if not self._queued then return end
    UIManager:unschedule(self._flush)
    self._queued = false
end

--- 档位已经写进 self.value。点按立刻画。拖动中最多 3Hz，每次挪档都把补帧推迟，停手才落到最后一档。
---@param self BookQuickPanelSliderRow
---@param live boolean|nil
function SliderRow:refresh(live)
    self:cancelPaint()
    if not live or self:paintDue() then
        self._last_paint = time.now()
        UIManager:setDirty(self.show_parent, "ui", self.dimen)
        return
    end
    self._queued = true
    UIManager:scheduleIn(DRAG_TRAIL, self._flush)
end

--- 触点落在左图标、轨道还是右图标。图标是加减一档，不是跳到两头。
---@param self BookQuickPanelSliderRow
---@param pos { x: number, y: number }|nil
---@return "down"|"track"|"up"|nil
function SliderRow:zone(pos)
    if not pos then return nil end
    local x = pos.x - self.dimen.x
    if x < self.bar_x then return "down" end
    if x >= self.bar_x + self.bar_w then return "up" end
    return "track"
end

--- 把轨道上的触点折成硬件档。亮度最低停在 floor，不到关灯那一档。
---@param self BookQuickPanelSliderRow
---@param pos { x: number, y: number }|nil
---@return number|nil
function SliderRow:stepFromPosition(pos)
    if not pos or self.bar_w <= 0 or self.max <= self.min then return nil end
    local t = clamp01((pos.x - self.dimen.x - self.bar_x) / self.bar_w)
    local step = self.min + math.floor(t * (self.max - self.min) + 0.5)
    if step < self.floor then step = self.floor end
    if step > self.max then step = self.max end
    return step
end

--- 档位变了才写硬件。fraction 是 setLevel 的逆运算：(档 - min) / (max - min)。
---@param self BookQuickPanelSliderRow
---@param step number
---@param live boolean|nil
---@return boolean
function SliderRow:commit(step, live)
    if step == self.value then return true end
    local fraction = (step - self.min) / (self.max - self.min)
    if not self.on_level(self.kind, fraction) then return false end
    self.value = step
    self:refresh(live)
    return true
end

--- 两端图标：减一档或加一档，夹在 floor..max。已经到头就不动。
---@param self BookQuickPanelSliderRow
---@param delta number
---@return boolean
function SliderRow:nudge(delta)
    if self.max <= self.min then return false end
    if delta < 0 and self.value <= self.floor then return true end
    if delta > 0 and self.value >= self.max then return true end
    local step = (delta > 0 and math.floor(self.value) or math.ceil(self.value)) + delta
    if step < self.floor then step = self.floor end
    if step > self.max then step = self.max end
    return self:commit(step, false)
end

--- 轨道上的点按和拖动。
---@param self BookQuickPanelSliderRow
---@param pos { x: number, y: number }|nil
---@param live boolean|nil
---@return boolean
function SliderRow:setFromPosition(pos, live)
    local step = self:stepFromPosition(pos)
    if not step then return false end
    return self:commit(step, live)
end

---@param self BookQuickPanelSliderRow
---@param _arg table|nil
---@param ges table|nil
---@return boolean
function SliderRow:onTap(_arg, ges)
    local pos = ges and ges.pos
    local zone = self:zone(pos)
    if zone == "down" then return self:nudge(-1) end
    if zone == "up" then return self:nudge(1) end
    return self:setFromPosition(pos, false)
end

---@param self BookQuickPanelSliderRow
---@param _arg table|nil
---@param ges table|nil
---@return boolean
function SliderRow:onPan(_arg, ges)
    -- 起点不在轨道上（从别处按住滑过来）一律不调，也不让手势继续往下传。
    local start = ges.start_pos
    local inside = start.y >= self.dimen.y and start.y < self.dimen.y + self.dimen.h
    if not inside or self:zone(start) ~= "track" or self:zone(ges.pos) ~= "track" then return true end
    local pos = ges.pos
    return self:setFromPosition(pos, true)
end

--- 松手时把被节流掉的最后一档画出来。
---@param self BookQuickPanelSliderRow
---@return boolean
function SliderRow:onPanRelease()
    if self._queued then
        self:cancelPaint()
        self._last_paint = time.now()
        UIManager:setDirty(self.show_parent, "ui", self.dimen)
    end
    return true
end

SliderRow.onHold = SliderRow.onTap
SliderRow.onHoldPan = SliderRow.onPan
SliderRow.onHoldRelease = SliderRow.onPanRelease

---@param self BookQuickPanelSliderRow
function SliderRow:free()
    self:cancelPaint()
    InputContainer.free(self)
end

---@param bb BlitBuffer
---@param x number
---@param y number
---@param w number
---@param h number
---@param token number
---@param radius number
local function paintPill(bb, x, y, w, h, token, radius)
    local color = Theme.color(token)
    local paint = wide(token) and bb.paintRoundedRectRGB32 or bb.paintRoundedRect
    paint(bb, x, y, w, h, color, radius)
end

--- 圆头滑轨。拇指按档位落在轨道内，填充画到拇指中心。
---@param self BookQuickPanelSliderRow
---@param bb BlitBuffer
---@param x number
---@param y number
function SliderRow:paintTrack(bb, x, y)
    local w, h = self.bar_w, self.dimen.h
    if w <= 0 or h <= 0 then return end
    local t = Theme.current()
    local track_h = math.min(self.track_h, h)
    local ty = y + math.floor((h - track_h) / 2)
    local radius = math.floor(track_h / 2)
    paintPill(bb, x, ty, w, track_h, t.progress.track, radius)
    local span = self.max - self.min
    local ratio = span > 0 and clamp01((self.value - self.min) / span) or 0
    local thumb = math.min(self.thumb_r, math.floor(h / 2))
    local left, right = x + thumb, x + w - thumb
    if right < left then left, right = x + math.floor(w / 2), x + math.floor(w / 2) end
    local cx = math.floor(left + ratio * (right - left) + 0.5)
    local fill_w = cx - x
    if fill_w > 0 then
        paintPill(bb, x, ty, math.min(fill_w, w), track_h, t.progress.fill, radius)
    end
    local cy = y + math.floor(h / 2)
    local ring = math.max(1, Theme.px(2))
    bb:paintCircle(cx, cy, thumb, Theme.color(t.color.ink))
    bb:paintCircle(cx, cy, math.max(1, thumb - ring), Theme.color(t.color.page))
end

--- 记下绝对坐标再画滑轨。InputContainer 会把 dimen 改成落点，手势区跟着走。
---@param self BookQuickPanelSliderRow
---@param bb BlitBuffer
---@param x number
---@param y number
function SliderRow:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)
    self:paintTrack(bb, self.dimen.x + self.bar_x, self.dimen.y)
end

---@type BookQuickPanelSliderRow
return SliderRow
