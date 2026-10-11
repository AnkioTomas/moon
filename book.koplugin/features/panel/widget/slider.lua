--[[-- 灯光滑杆行。
@module koplugin.book.features.panel.widget.slider
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Progress = require("ui.themes.widgets.progress")
local Text = require("ui.themes.widgets.text")
local Theme = require("ui.themes")

--- 灯光滑杆行：标题、进度条和百分比数值。
---@class BookQuickPanelSliderRow : InputContainer
---@field width number
---@field height number
---@field kind "brightness"|"warmth"
---@field title string
---@field value number
---@field on_level fun(kind: string, fraction: number): boolean|nil
---@field show_parent table
---@field bar_x number
---@field bar_w number
---@field progress table
---@field value_label table
---@field setFromPosition fun(self: BookQuickPanelSliderRow, pos: { x: number, y: number }|nil): boolean

local SliderRow = InputContainer:extend{}

--- 初始化手势区、进度条和数值标签。
---@param self BookQuickPanelSliderRow
function SliderRow:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    local t = Theme.current()
    local label_w, value_w = Theme.px(72), Theme.px(42)
    local gap = Theme.px(t.space.sm)
    local bar_w = self.width - label_w - value_w - gap * 2
    self.bar_x, self.bar_w = label_w + gap, bar_w
    self.progress = Progress:new{ width = bar_w, height = Theme.px(t.control.icon), percent = self.value }
    self.value_label = Text.line("caption", string.format("%d%%", self.value), { width = value_w })
    local value_box = CenterContainer:new{
        dimen = Geom:new{ w = value_w, h = self.height },
        self.value_label,
    }
    self[1] = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = label_w, h = self.height },
            Text.line("body", self.title, { width = label_w }),
        },
        HorizontalSpan:new{ width = gap },
        self.progress,
        HorizontalSpan:new{ width = gap },
        value_box,
    }
end

--- 根据点击位置更新亮度或暖色并刷新 UI。
---@param self BookQuickPanelSliderRow
---@param pos { x: number, y: number }|nil
---@return boolean
function SliderRow:setFromPosition(pos)
    if not pos then return false end
    local fraction = math.max(0, math.min(1, (pos.x - self.dimen.x - self.bar_x) / self.bar_w))
    local value = math.floor(fraction * 100 + 0.5)
    if value == self.value then return true end
    if not self.on_level(self.kind, fraction) then return false end
    self.value = value
    self.progress:setPercent(value)
    self.value_label:setText(string.format("%d%%", value))
    UIManager:setDirty(self.show_parent, "ui", self.dimen)
    return true
end

--- 点击滑杆时设置当前值。
---@param self BookQuickPanelSliderRow
---@param _arg table|nil
---@param ges table|nil
---@return boolean
function SliderRow:onTap(_arg, ges) return self:setFromPosition(ges and ges.pos) end

---@type BookQuickPanelSliderRow
return SliderRow
