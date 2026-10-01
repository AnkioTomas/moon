--[[--
主题输入框（替代 InputDialog / MultiInputDialog）：一个或多个输入字段 + 取消 / 确定。
面板贴顶，给虚拟键盘让位。

  +-------------------------+
  | 标题                    |
  | 账号                    |   label 可选
  | [ ankio              ]  |   焦点字段描 ink 色，其余 rule 色
  | 密码                    |
  | [ ••••               ]  |
  | [ 取消 ]    [█确定█]    |
  +-------------------------+
  |       虚拟键盘          |
  +-------------------------+

  Input:new{
      title = "登录",
      fields = {
          { label = "账号", text = "", hint = "邮箱" },
          { label = "密码", text_type = "password" },
          { label = "简介", height = 120 },          -- 给 height（逻辑像素）即多行
      },
      callback = function(account, password, intro) … end,   -- 按字段顺序传文本
      actions = { { text = "测试", callback = function(account, …) … end } },  -- 可选
  }:show()

actions 插在取消与确定之间，按字段顺序收文本，点了不关窗（测试、预览这类）。

编辑内核仍是 KOReader InputText：虚拟键盘与 ime/ 的中文输入法都挂在它上面，外框和焦点样式由主题接管。
InputText 的文本区固定铺白底，所以字段框底色用 color.page，并至少描 1px 边（soft 的控件无边）。
点面板外：键盘开着先收键盘，否则等同取消。

@module koplugin.book.ui.themes.widgets.input
--]]

require("l10n").apply()

local InputText = require("ui/widget/inputtext")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Modal = require("ui.themes.widgets.modal")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")

---@class BookThemeInputField
---@field text string|nil
---@field hint string|nil
---@field label string|nil
---@field input_type string|nil "number" 等，透传 InputText
---@field text_type string|nil "password" 等，透传 InputText
---@field height number|nil 逻辑像素；给了即多行可滚动

---@class BookThemeInput : BookThemeModal
---@field title string|nil
---@field fields BookThemeInputField[]
---@field ok_text string|nil
---@field cancel_text string|nil
---@field callback fun(...: string)|nil
---@field cancel_callback fun()|nil
---@field actions { text: string, callback: fun(...: string) }[]|nil 额外按钮，不关窗
local Input = Modal:extend{
    anchor = "top",
    title = nil,
    fields = nil,
    ok_text = nil,
    cancel_text = nil,
    callback = nil,
    cancel_callback = nil,
    actions = nil,
}

function Input:init()
    Modal.init(self)
    local t = self.theme
    local inner = self:innerWidth()
    local pad = Theme.px(t.space.sm)
    self.inputs, self.frames = {}, {}
    self.focus_idx = 1
    local body = VerticalGroup:new{ align = "left" }
    for i, field in ipairs(self.fields) do
        if i > 1 then body[#body + 1] = VerticalSpan:new{ width = Theme.px(t.space.md) } end
        if field.label then
            body[#body + 1] = Text.line("caption", field.label, { width = inner, color = t.color.muted })
            body[#body + 1] = VerticalSpan:new{ width = Theme.px(t.space.xs) }
        end
        local input = InputText:new{
            text = field.text or "",
            hint = field.hint or "",
            input_type = field.input_type,
            text_type = field.text_type,
            width = inner - pad * 2,
            height = field.height and Theme.px(field.height),
            scroll = field.height ~= nil,
            face = Text.face("body"),
            bordersize = 0,
            padding = 0,
            margin = 0,
            focused = i == 1,
            parent = self,
        }
        local frame = Box:new{
            style = {
                bg = t.color.page,
                border = math.max(1, t.control.border),
                border_color = i == 1 and t.color.ink or t.color.rule,
                radius = t.control.radius,
            },
            padding = pad,
            width = inner,
            input,
        }
        self.inputs[i], self.frames[i] = input, frame
        body[#body + 1] = frame
    end
    local buttons = { { text = self.cancel_text or _("取消"), callback = function() self:dismiss() end } }
    for _i, action in ipairs(self.actions or {}) do
        buttons[#buttons + 1] = { text = action.text, callback = function() action.callback(unpack(self:texts())) end }
    end
    buttons[#buttons + 1] = { text = self.ok_text or _("确定"), variant = "primary", callback = function() self:confirm() end }
    self:setDialog{ title = self.title, body = body, buttons = buttons }
end

function Input:onShow()
    self.inputs[self.focus_idx]:onShowKeyboard()
end

--- InputText 被点按时回调（含已聚焦字段）：切焦点、换键盘、改描边。
---@param input table InputText
function Input:onSwitchFocus(input)
    local cur = self.inputs[self.focus_idx]
    if input ~= cur then
        cur:unfocus()
        cur:onCloseKeyboard()
        input:focus()
        local t = self.theme
        for i, it in ipairs(self.inputs) do
            if it == input then self.focus_idx = i end
            self.frames[i].style.border_color = it == input and t.color.ink or t.color.rule
        end
        UIManager:setDirty(self, function() return "ui", self[1].dimen end)
    end
    input:onShowKeyboard()
end

---@param arg any
---@param ges table
---@return boolean
function Input:onTapModal(arg, ges)
    local input = self.inputs[self.focus_idx]
    if not ges.pos:intersectWith(self[1].dimen) and input:isKeyboardVisible() then
        input:onCloseKeyboard()
        return true
    end
    return Modal.onTapModal(self, arg, ges)
end

--- 各字段当前文本，按字段顺序。
---@return string[]
function Input:texts()
    local texts = {}
    for i, input in ipairs(self.inputs) do texts[i] = input:getText() end
    return texts
end

function Input:confirm()
    local texts = self:texts()
    self:close()
    if self.callback then self.callback(unpack(texts)) end
end

function Input:dismiss()
    self:close()
    if self.cancel_callback then self.cancel_callback() end
end

function Input:onCloseWidget()
    for _i, input in ipairs(self.inputs) do input:onCloseKeyboard() end
    Modal.onCloseWidget(self)
end

return Input
