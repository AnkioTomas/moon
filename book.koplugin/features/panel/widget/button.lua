--[[-- 快捷动作按钮：形状跟主题令牌 `tile.shape` 走。

  bare    无框图标，开着的项垫 primary 底（paper）
  circle  圆形底座，文字在圆外（soft）
  block   灰色胶囊磁贴，文字在内（bold）

@module koplugin.book.features.panel.widget.button
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Icon = require("ui.themes.widgets.icon")
local Box = require("ui.themes.widgets.box")
local Text = require("ui.themes.widgets.text")
local Theme = require("ui.themes")

-- 底座边长（逻辑像素）：bare 只是图标的垫底，circle 是整颗按钮。
local BADGE_SIZE = { bare = 44, circle = 52 }

--- 单个快捷动作按钮：图标、文字、激活态和点击回调。
---@class BookQuickPanelActionButton : InputContainer
---@field width number
---@field height number
---@field id string
---@field title string
---@field icon string
---@field active boolean|nil
---@field on_action fun(id: string)
---@field on_hold fun(): boolean|nil

local ActionButton = InputContainer:extend{}

--- 按钮变体的表面令牌：有 border_color 才画边。
---@param t table 主题令牌
---@param v table button.normal / button.primary
---@param radius number
---@return table
local function surface(t, v, radius)
    return {
        bg = v.bg,
        border = v.border_color and t.control.border or 0,
        border_color = v.border_color or 0,
        radius = radius,
    }
end

--- 灰色胶囊磁贴：未选浅灰 0xEE、选中中灰 0xC4，图标和文字都在里面。
---@param self BookQuickPanelActionButton
---@param t table
---@param active boolean
---@return table
local function block(self, t, active)
    return Box:new{
        style = { bg = active and 0xC4 or 0xEE, radius = 999 },
        width = self.width,
        height = self.height,
        Icon.label{
            name = self.icon,
            text = self.title,
            direction = "column",
            size = t.control.icon,
            color = Blitbuffer.Color8(t.color.ink),
            font_size = t.font.caption,
            max_width = math.max(Theme.px(36), self.width - Theme.px(t.space.sm)),
            gap = Theme.px(2),
        },
    }
end

--- 底座图标 + 下方文字：circle 总画圆底；bare 只有开着才垫 primary 底。
---@param self BookQuickPanelActionButton
---@param t table
---@param v table
---@param active boolean
---@param shape "bare"|"circle"
---@return table
local function badge(self, t, v, active, shape)
    local filled = shape == "circle" or active
    local style = filled and surface(t, v, shape == "circle" and 999 or t.control.radius) or {}
    local size = Theme.px(BADGE_SIZE[shape])
    return CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        VerticalGroup:new{
            align = "center",
            Box:new{
                style = style,
                width = size,
                height = size,
                Icon.widget{
                    name = self.icon,
                    size = t.control.icon,
                    color = Blitbuffer.Color8(filled and v.ink or t.color.ink),
                },
            },
            VerticalSpan:new{ width = Theme.px(t.space.xs) },
            Text.line("caption", self.title, { width = self.width, color = t.color.ink }),
        },
    }
end

--- 按主题磁贴形状构造按钮。
---@param self BookQuickPanelActionButton 当前视图或布局实例
function ActionButton:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    local active = self.active == true
    local t = Theme.current()
    local v = active and t.button.primary or t.button.normal
    local shape = t.tile.shape
    if shape == "block" then
        self[1] = block(self, t, active)
    else
        self[1] = badge(self, t, v, active, shape)
    end
end

--- 处理按钮点击。
---@param self BookQuickPanelActionButton 当前视图或布局实例
---@return boolean
function ActionButton:onTap()
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
