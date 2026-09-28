--[[--
主题按钮：文字 / 图标 / 图标+文字，三种变体取 theme.button 令牌。

  [  文案  ]   normal   浅底或描边
  [██文案██]   primary  实心反色（确认、选中的筛选 chip）
     文案      ghost    无底无边（标题栏、翻页条图标）

  Button:new{ text = "确定", icon = "check", variant = "primary", width = w, callback = fn }

width/height 是物理像素：缺省宽按内容加左右内边距，高取 control.height。
enabled=false 时文字与边框改 disabled 色，点按被吞掉不回调。

@module koplugin.book.ui.themes.widgets.button
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Icon = require("ui.themes.widgets.icon")
local Theme = require("ui.themes.init")
local Box = require("ui.themes.widgets.box")
local Text = require("ui.themes.widgets.text")

---@class BookThemeButton : InputContainer
---@field text string|nil
---@field icon string|nil Material 图标名
---@field variant string normal/primary/ghost
---@field enabled boolean
---@field width number|nil
---@field height number|nil
---@field callback fun()|nil
local Button = InputContainer:extend{
    text = nil,
    icon = nil,
    variant = "normal",
    enabled = true,
    width = nil,
    height = nil,
    callback = nil,
}

--- 按钮内容：图标、文字或两者横排。
---@param t table 主题令牌
---@param ink number 灰度令牌
---@param max_w number|nil 物理像素
---@return table
function Button:content(t, ink, max_w)
    if self.icon and self.text then
        return Icon.label{
            name = self.icon,
            text = self.text,
            size = t.control.icon,
            color = Blitbuffer.Color8(ink),
            face = "cfont",
            font_size = t.font.body,
            gap = Theme.px(t.space.xs),
            max_width = max_w,
        }
    end
    if self.icon then
        return Icon.widget{ name = self.icon, size = t.control.icon, color = Blitbuffer.Color8(ink) }
    end
    return Text.line("body", self.text, { width = max_w, color = ink })
end

function Button:init()
    local t = Theme.current()
    local v = t.button[self.variant]
    local ink = self.enabled and v.ink or t.color.disabled
    local pad = Theme.px(t.space.md)
    local content = self:content(t, ink, self.width and math.max(1, self.width - pad * 2))
    local border_color = v.border_color and (self.enabled and v.border_color or t.color.disabled)
    self[1] = Box:new{
        style = {
            bg = v.bg,
            border = border_color and t.control.border or 0,
            border_color = border_color,
            radius = t.control.radius,
        },
        width = self.width or content:getSize().w + pad * 2,
        height = self.height or Theme.px(t.control.height),
        content,
    }
    local size = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
    self.ges_events = {
        TapThemeButton = {
            GestureRange:new{ ges = "tap", range = function() return self.dimen end },
        },
    }
end

---@return boolean
function Button:onTapThemeButton()
    if self.enabled and self.callback then self.callback() end
    return true
end

return Button
