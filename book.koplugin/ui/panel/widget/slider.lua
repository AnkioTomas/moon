--[[-- 灯光滑杆行。
@module koplugin.book.ui.panel.widget.slider
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local UI = require("ui.components.bookui")

--- 灯光滑杆行：标题、进度条和百分比数值。
---@class BookQuickPanelSliderRow : WidgetContainer
---@field width number
---@field height number
---@field kind "brightness"|"warmth"
---@field title string
---@field value number
---@field on_level fun(kind: string, fraction: number): boolean|nil
---@field bar_x number
---@field bar_w number
---@field progress table
---@field value_label table

local SliderRow = InputContainer:extend{}

--- 初始化手势区、进度条和数值标签。
---@param self BookQuickPanelSliderRow
---@return void
function SliderRow:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Pan = { GestureRange:new{ ges = "pan", range = self.dimen } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = self.dimen } },
    }
    local label_w, value_w = UI.sz(72), UI.sz(42)
    local bar_w = self.width - label_w - value_w - UI.sz(16)
    self.bar_x, self.bar_w = label_w + UI.sz(8), bar_w
    self.progress = UI.progressBar(bar_w, UI.sz(22), self.value)
    self.value_label = TextWidget:new{
        text = string.format("%d%%", self.value),
        face = UI.face("xx_smallinfofont", 12),
        max_width = value_w,
    }
    local value_box = CenterContainer:new{
        dimen = Geom:new{ w = value_w, h = self.height },
        self.value_label,
    }
    self[1] = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = label_w, h = self.height },
            TextWidget:new{ text = self.title, face = UI.face("cfont", 13), max_width = label_w },
        },
        HorizontalSpan:new{ width = UI.sz(8) },
        self.progress,
        HorizontalSpan:new{ width = UI.sz(8) },
        value_box,
    }
end

--- 根据点击/拖拽位置更新亮度或暖色并刷新 UI。
---@param self BookQuickPanelSliderRow
---@param pos { x: number, y: number }|nil
---@return boolean
function SliderRow:setFromPosition(pos)
    if not pos then return false end
    local fraction = math.max(0, math.min(1, (pos.x - self.dimen.x - self.bar_x) / self.bar_w))
    if not self.on_level(self.kind, fraction) then return false end
    local value = math.floor(fraction * 100 + 0.5)
    self.progress:setPercent(value)
    self.value_label:setText(string.format("%d%%", value))
    UIManager:setDirty(self, "ui")
    return true
end

--- 点击滑杆时设置当前值。
---@param self BookQuickPanelSliderRow
---@param _ table|nil
---@param ges table|nil
---@return boolean
function SliderRow:onTap(_, ges) return self:setFromPosition(ges and ges.pos) end
--- 拖拽滑杆时设置当前值。
---@param self BookQuickPanelSliderRow
---@param _ table|nil
---@param ges table|nil
---@return boolean
function SliderRow:onPan(_, ges) return self:setFromPosition(ges and ges.pos) end
--- 松开拖拽时设置当前值。
---@param self BookQuickPanelSliderRow
---@param _ table|nil
---@param ges table|nil
---@return boolean
function SliderRow:onPanRelease(_, ges) return self:setFromPosition(ges and ges.pos) end

---@type BookQuickPanelSliderRow
return SliderRow
