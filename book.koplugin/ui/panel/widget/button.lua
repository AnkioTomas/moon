--[[-- 圆润胶囊快捷动作按钮。
@module koplugin.book.ui.panel.widget.button
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Icon = require("ui.components.icon")
local Surface = require("ui.components.surface")
local UI = require("ui.components.bookui")

--- 单个快捷动作按钮：图标、文字、激活态和点击回调。
---@class BookQuickPanelActionButton : InputContainer
---@field width number
---@field height number
---@field id string
---@field title string
---@field icon string
---@field active boolean|nil
---@field enabled boolean|nil
---@field on_action fun(id: string)
---@field on_hold fun(): boolean|nil

local ActionButton = InputContainer:extend{}

--- 根据宽高、图标、标题和状态构造胶囊按钮。
---@param self BookQuickPanelActionButton 当前视图或布局实例
function ActionButton:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    local enabled = self.enabled ~= false
    local active = enabled and self.active == true
    local color = Blitbuffer.COLOR_BLACK
    self[1] = Surface.build{ child = Icon.label{
        name = self.icon,
        text = self.title,
        direction = "column",
        color = color,
        face = "xx_smallinfofont",
        font_size = 11,
        max_width = math.max(UI.sz(36), self.width - UI.sz(8)),
        gap = UI.sz(2),
        dim = not enabled,
    }, options = {
        width = self.width,
        height = self.height,
        background = active and UI.actionSurface() or UI.surface(),
        shadow = false,
    }, kind = "pill" }
end

--- 处理按钮点击；禁用时吞掉事件，不触发动作。
---@param self BookQuickPanelActionButton 当前视图或布局实例
---@return boolean
function ActionButton:onTap()
    if self.enabled == false then return true end
    self.on_action(self.id)
    return true
end

--- 长按交给上层（用于进入现场编辑）。
---@param self BookQuickPanelActionButton
---@return boolean|nil 是否已消费
function ActionButton:onHold()
    if self.on_hold then return self.on_hold() end
    return false
end

---@type BookQuickPanelActionButton
return ActionButton
