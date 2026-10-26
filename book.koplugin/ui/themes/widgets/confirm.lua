--[[--
主题确认框（替代 ConfirmBox）。点面板外 / 返回键等同「取消」。

  +----------------------+
  | 标题（可选）         |
  | 确定删除这本书？     |
  | [ 取消 ]  [█确定█]   |
  +----------------------+

  Confirm:new{ text = "…", ok_text = _("删除"), ok_callback = fn, cancel_callback = fn }:show()

两个回调都在关窗之后调用，回调里可以直接弹下一个窗。
给了 extra_text 时在取消与确定之间多一个中性按钮（extra_callback，同样先关窗再回调）。

@module koplugin.book.ui.themes.widgets.confirm
--]]

require("l10n").apply()

local Modal = require("ui.themes.widgets.modal")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")

---@class BookThemeConfirm : BookThemeModal
---@field title string|nil
---@field text string
---@field ok_text string|nil
---@field cancel_text string|nil
---@field extra_text string|nil 中间的第三个按钮；不给就没有
---@field ok_callback fun()|nil
---@field cancel_callback fun()|nil
---@field extra_callback fun()|nil
local Confirm = Modal:extend{
    title = nil,
    text = nil,
    ok_text = nil,
    cancel_text = nil,
    extra_text = nil,
    ok_callback = nil,
    cancel_callback = nil,
    extra_callback = nil,
}

function Confirm:init()
    Modal.init(self)
    local t = self.theme
    local buttons = {
        { text = self.cancel_text or _("取消"), callback = function() self:dismiss() end },
    }
    if self.extra_text then
        buttons[#buttons + 1] = { text = self.extra_text, callback = function() self:extra() end }
    end
    buttons[#buttons + 1] = { text = self.ok_text or _("确定"), variant = "primary", callback = function() self:confirm() end }
    self:setDialog{
        title = self.title,
        body = Text.box("body", self.text, self:innerWidth(), { bg = t.dialog.bg }),
        buttons = buttons,
    }
end

function Confirm:extra()
    self:close()
    if self.extra_callback then self.extra_callback() end
end

function Confirm:confirm()
    self:close()
    if self.ok_callback then self.ok_callback() end
end

function Confirm:dismiss()
    self:close()
    if self.cancel_callback then self.cancel_callback() end
end

return Confirm
