--[[--
主题模态底座：网状遮罩 + 一块面板（Box），替代 KOReader 各类弹窗的外壳。

  +----------------------------+
  |░░░░░░░░░░░░░░░░░░░░░░░░░░░░|   mask=true 画网状遮罩（受 display.mesh_mask 开关）
  |░░░░ +----------------+ ░░░░|
  |░░░░ | 标题           | ░░░░|   anchor=center 居中；top 贴顶（给键盘让位）
  |░░░░ | 正文           | ░░░░|
  |░░░░ | [取消] [确定]  | ░░░░|
  |░░░░ +----------------+ ░░░░|
  +----------------------------+

子类在 init 里先 Modal.init(self)，再 setDialog{...}（标准面板）或 setPanel(box)（自定义）。
点面板外 / 返回键：dismissable 时走 dismiss()（默认关窗，子类覆盖为「取消」语义），否则只吞事件。
关窗后 close_callback 调一次。

@module koplugin.book.ui.themes.widgets.modal
--]]

local Device = require("device")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local MeshMask = require("ui.components.meshmask")
local UI = require("ui.components.bookui")
local Theme = require("ui.themes.init")
local Box = require("ui.themes.widgets.box")
local Button = require("ui.themes.widgets.button")
local Text = require("ui.themes.widgets.text")
local Screen = Device.screen

---@class BookThemeModal : InputContainer
---@field dismissable boolean 点面板外 / 返回键是否关闭
---@field close_on_tap boolean 面板内外任意点按都直接关窗（提示、进度、二维码这类无交互面板）
---@field anchor string center/top
---@field mask boolean 是否画网状遮罩；全屏页传 false
---@field close_callback fun()|nil
---@field theme table 构造时的主题令牌
local Modal = InputContainer:extend{
    dismissable = true,
    close_on_tap = false,
    anchor = "center",
    mask = true,
    close_callback = nil,
}

--- 标准弹窗宽度：屏宽留两侧边距，封顶避免横屏过宽。
---@param t table 主题令牌
---@return number 物理像素
function Modal.dialogWidth(t)
    return math.min(Screen:getWidth() - Theme.px(t.space.lg) * 4, UI.sz(480))
end

function Modal:init()
    self.theme = Theme.current()
    self.dimen = Screen:getSize()
    if self.mask then
        self._mask = MeshMask.widget{ width = self.dimen.w, height = self.dimen.h }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self.ges_events.TapModal = {
        GestureRange:new{ ges = "tap", range = self.dimen },
    }
end

--- 放入面板并按 anchor 定位。
---@param panel table Box
function Modal:setPanel(panel)
    self[1] = panel
    local size = panel:getSize()
    self.panel_x = math.floor((self.dimen.w - size.w) / 2)
    self.panel_y = self.anchor == "top" and Theme.px(self.theme.space.lg)
        or math.floor((self.dimen.h - size.h) / 2)
end

--- 等宽按钮行；每项 { text, icon, variant, enabled, callback }。
---@param specs table[]
---@param width number 物理像素
---@return table
function Modal:buttonRow(specs, width)
    local gap = Theme.px(self.theme.space.sm)
    local bw = math.floor((width - gap * (#specs - 1)) / #specs)
    local row = HorizontalGroup:new{ align = "center" }
    for i, spec in ipairs(specs) do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = Button:new{
            text = spec.text,
            icon = spec.icon,
            variant = spec.variant or "normal",
            enabled = spec.enabled ~= false,
            width = bw,
            callback = spec.callback,
        }
    end
    return row
end

--- 标准面板：标题 + 正文 + 底部按钮行。body 宽度应为 Modal:innerWidth()。
---@param opts { title?: string, body?: table, buttons?: table[] }
function Modal:setDialog(opts)
    local t = self.theme
    local inner = self:innerWidth()
    -- 撑宽占位：面板宽度固定，内容左对齐，不随文案长短变化。
    local group = VerticalGroup:new{ align = "left", HorizontalSpan:new{ width = inner } }
    if opts.title then
        group[#group + 1] = Text.line(t, "title", opts.title, { width = inner })
        group[#group + 1] = VerticalSpan:new{ width = Theme.px(t.space.md) }
    end
    if opts.body then
        group[#group + 1] = opts.body
    end
    if opts.buttons and #opts.buttons > 0 then
        group[#group + 1] = VerticalSpan:new{ width = Theme.px(t.space.lg) }
        group[#group + 1] = self:buttonRow(opts.buttons, inner)
    end
    local pad = Theme.px(t.space.lg)
    self:setPanel(Box:new{ style = t.dialog, padding = pad, width = inner + pad * 2, group })
end

--- 标准面板内容宽度。
---@return number 物理像素
function Modal:innerWidth()
    return Modal.dialogWidth(self.theme) - Theme.px(self.theme.space.lg) * 2
end

---@param bb BlitBuffer 目标画布
---@param x number
---@param y number
function Modal:paintTo(bb, x, y)
    if self._mask then self._mask:paintTo(bb, x, y) end
    self[1]:paintTo(bb, x + self.panel_x, y + self.panel_y)
end

function Modal:show()
    UIManager:show(self, "ui")
end

function Modal:close()
    UIManager:close(self, "ui")
end

--- 用户放弃（点面板外 / 返回键）；子类覆盖为取消语义。
function Modal:dismiss()
    self:close()
end

---@param _arg any
---@param ges table
---@return boolean
function Modal:onTapModal(_arg, ges)
    if self.close_on_tap then
        self:close()
        return true
    end
    if ges.pos:intersectWith(self[1].dimen) then return true end
    if self.dismissable then self:dismiss() end
    return true
end

---@return boolean
function Modal:onClose()
    if self.dismissable then self:dismiss() end
    return true
end

function Modal:onCloseWidget()
    local cb = self.close_callback
    self.close_callback = nil
    if cb then cb() end
end

return Modal
