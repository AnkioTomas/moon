--[[--
主题模态底座：网状遮罩 + 一块面板（Box），替代 KOReader 各类弹窗的外壳。

  +----------------------------+
  |░░░░░░░░░░░░░░░░░░░░░░░░░░░░|   mask=true 画网状遮罩（受 ui.mesh_mask 开关）
  |░░░░ +----------------+ ░░░░|
  |░░░░ | 标题           | ░░░░|   anchor=center 居中；top 贴顶（给键盘让位）；
  |░░░░ |                | ░░░░|   给矩形 {x,y,w,h} 则贴其下方弹出，放不下翻到上方，左右夹进屏内
  |░░░░ | 正文           | ░░░░|
  |░░░░ | [取消] [确定]  | ░░░░|
  |░░░░ +----------------+ ░░░░|
  +----------------------------+

子类在 init 里先 Modal.init(self)，再 setDialog{...}（标准面板）或 setPanel(box)（自定义）。
点面板外 / 返回键：dismissable 时走 dismiss()（默认关窗，子类覆盖为「取消」语义），否则只吞事件。
下滑关闭默认跟随全局开关 ui.swipe_dismiss（设置页「显示」，默认下滑），实例可显式设 swipe_dismiss 覆盖。
关窗后 close_callback 调一次。
给了 width / height 时按该尺寸布局（缺省整屏），可嵌进别的窗口：宿主设 show_parent 为所在顶层窗口，
子类重画时 setDirty(show_parent)；绘制时记下自身坐标，点击范围跟着走。

@module koplugin.book.ui.themes.widgets.modal
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Guard = require("ui.guard")
local Ext = require("utils.extension")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Button = require("ui.themes.widgets.button")
local Mask = require("ui.themes.widgets.mask")
local Text = require("ui.themes.widgets.text")
local MoonSettings = require("utils.settings")
local Screen = Device.screen

---@class BookThemeModal : InputContainer
---@field closed boolean|nil 窗口已关闭
---@field title string|nil 窗口标题
---@field updateView fun(self: BookThemeModal)|nil 子类重建入口
---@field dismissable boolean 点面板外 / 返回键是否关闭
---@field close_on_tap boolean 面板内外任意点按都直接关窗（提示、二维码这类无交互面板）；dismissable=false 时不生效
---@field swipe_dismiss string|nil 面板内外下滑直接关窗（走 dismiss 语义）："down"（下滑）/"up"（上滑）/"off"（关闭）；
---  nil（默认）跟随全局开关 ui.swipe_dismiss，显式值覆盖全局开关；子类内容自己消费下滑手势时（如内嵌 List）应显式设 "off"
---@field anchor string|table center/top，或锚点矩形 {x,y,w,h}（物理像素，如按钮 dimen）
---@field mask boolean 只读：是否画网状遮罩，由 covers_fullscreen 推出（弹窗不能自行关闭，只受全局 ui.mesh_mask）
---@field close_callback fun()|nil
---@field width number|nil 布局宽度（物理像素）；缺省整屏
---@field height number|nil 布局高度（物理像素）；缺省整屏
---@field show_parent table|nil 嵌进别的窗口时所在的顶层窗口
---@field theme table 构造时的主题令牌
local Modal = InputContainer:extend{
    -- 月读自己的窗口：退出兜底（BookPlugin:onExit）按此标记清理残留
    book_window = true,
    dismissable = true,
    close_on_tap = false,
    anchor = "center",
    close_callback = nil,
    width = nil,
    height = nil,
    show_parent = nil,
}

--- 标准弹窗宽度：屏宽留两侧边距，封顶避免横屏过宽。
---@return number 物理像素
function Modal.dialogWidth()
    local t = Theme.current()
    return math.min(Screen:getWidth() - Theme.px(t.space.lg) * 4, Theme.px(480))
end

--- 下滑关闭是否生效：实例显式设过 swipe_dismiss 时优先，否则跟随全局开关 ui.swipe_dismiss。
local SWIPE_DISMISS_DIRECTIONS = { down = "south", up = "north" }
---@param self BookThemeModal
---@return string|nil "south"/"north"（对应手势方向），nil 表示不生效
local function swipeDismissDirection(self)
    local mode = self.swipe_dismiss
    if mode == nil then
        mode = MoonSettings.get("ui").swipe_dismiss
    end
    return SWIPE_DISMISS_DIRECTIONS[mode]
end

function Modal:init()
    self.theme = Theme.current()
    local screen = Screen:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width or screen.w, h = self.height or screen.h }
    self.mask = not self.covers_fullscreen
    if self.mask then
        self._mask = Mask:new{ dimen = self.dimen }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self.ges_events.TapModal = {
        GestureRange:new{ ges = "tap", range = self.dimen },
    }
    self._swipe_direction = swipeDismissDirection(self)
    if self._swipe_direction then
        self.ges_events.SwipeModal = {
            GestureRange:new{ ges = "swipe", range = self.dimen },
        }
    end
end

--- 放入面板并按 anchor 定位。
---@param panel table Box
function Modal:setPanel(panel)
    self[1] = panel
    local size = panel:getSize()
    local a = self.anchor
    if type(a) == "table" then
        local m = Theme.px(self.theme.space.sm)
        local below = a.y + a.h
        self.panel_x = math.max(m, math.min(a.x + math.floor((a.w - size.w) / 2), self.dimen.w - size.w - m))
        self.panel_y = below + size.h <= self.dimen.h - m and below or math.max(m, a.y - size.h)
        return
    end
    self.panel_x = math.floor((self.dimen.w - size.w) / 2)
    self.panel_y = a == "top" and Theme.px(self.theme.space.lg)
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
        group[#group + 1] = Text.line("title", opts.title, { width = inner })
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
    return Modal.dialogWidth() - Theme.px(self.theme.space.lg) * 2
end

---@param self BookThemeModal
---@param bb BlitBuffer
---@param x number
---@param y number
---@return true
local function paint(self, bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    Ext.call("modal.backdrop", self, bb, x, y)
    if self._mask then self._mask:paintTo(bb, x, y) end
    self[1]:paintTo(bb, x + self.panel_x, y + self.panel_y)
    return true
end

--- 经 guard 隔离。画坏的弹窗不能只停画：它仍在栈顶，会成为吞掉全部点按的隐形窗口，
--- 所以报告后关掉它；UIManager 正在遍历窗口栈重绘，关窗推到下一 tick。
---@param bb BlitBuffer 目标画布
---@param x number
---@param y number
function Modal:paintTo(bb, x, y)
    if self._paint_broken then return end
    if Guard.call("modal paint", paint, self, bb, x, y) then return end
    self._paint_broken = true
    UIManager:nextTick(function() self:close() end)
end

--- 弹窗内全部点按 / 按键的入口，经 guard 隔离；出错这次事件算已处理，不漏到下层窗口。
--- UIManager 的 __default__ 会把没登记的原始输入（如模拟器的电源键松开）原样发来，可能不是 Event、没有 handler。
---@param event table|string KOReader 事件
---@return boolean|nil
function Modal:handleEvent(event)
    local ok, handled = Guard.call("modal " .. tostring(event.handler or event), function()
        return true, InputContainer.handleEvent(self, event)
    end)
    if not ok then return true end
    return handled
end

--- 网点遮罩叠在旧像素上，局刷会留残影：带遮罩（且设置开着网点）弹出时全刷。
function Modal:show()
    -- 退出已开始：此后再弹的窗口（关书时的错误页、提示）会让 KOReader 等不到空栈而假死
    if require("ui.exit_windows").exiting then
        require("utils.log").warn("book exit suppressed window", self.name or self.title)
        return
    end
    UIManager:show(self, self._mask and MoonSettings.get("ui").mesh_mask and "full" or "ui")
end

function Modal:close()
    UIManager:close(self, "ui")
end

--- 旋转屏幕后按新屏幕重排。dimen 与遮罩、点按区共用同一张表，原地改尺寸即可；
--- 有 updateView 的整屏页（设置叠层、详情）重建内容，其余弹窗保持面板、重新居中。
--- 旋转由 FileManager 在同一次广播里完成，所以等下一 tick 屏幕尺寸才是新的。
function Modal:relayout()
    if self.closed then return end
    local screen = Screen:getSize()
    local w, h = self.width or screen.w, self.height or screen.h
    if self.dimen.w == w and self.dimen.h == h then return end
    self.dimen.w, self.dimen.h = w, h
    if self.updateView then
        self:updateView()
    else
        self:setPanel(self[1])
    end
    UIManager:setDirty(self, "full")
end

local function scheduleRelayout(self)
    UIManager:nextTick(function() Guard.call("modal relayout", self.relayout, self) end)
    return false
end

Modal.onSetRotationMode = scheduleRelayout
Modal.onScreenResize = scheduleRelayout

--- 用户放弃（点面板外 / 返回键）；子类覆盖为取消语义。
function Modal:dismiss()
    self:close()
end

---@param _arg any
---@param ges table
---@return boolean
function Modal:onTapModal(_arg, ges)
    if self.close_on_tap and self.dismissable then
        self:close()
        return true
    end
    if ges.pos:intersectWith(self[1].dimen) then return true end
    if self.dismissable then self:dismiss() end
    return true
end

--- 下滑关闭（面板内外都触发，和点按不同：点面板内容是故意要能拖拽关闭）。
---@param _arg any
---@param ges table
---@return boolean
function Modal:onSwipeModal(_arg, ges)
    if self.dismissable and ges.direction == self._swipe_direction then
        self:dismiss()
    end
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
