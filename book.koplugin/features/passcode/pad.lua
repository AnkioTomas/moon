--[[--
密码数字键盘：整屏面板，圆点显示已输位数，下面是 3×4 键盘。

  +----------------------+
  |     输入密码解锁     |
  |     ● ● ○ ○ ○ ○      |
  |     密码错误         |
  |   [1]  [2]  [3]      |
  |   [4]  [5]  [6]      |
  |   [7]  [8]  [9]      |
  |   [⌫]  [0]  [✓]      |
  |      [ 取消 ]        |   仅 dismissable
  +----------------------+

on_submit(pin) 返回 true 关窗；返回字符串则清空输入、显示该提示。
dismissable=false（解锁）时返回键、点空白都被吞掉；true（设置页）时多一个取消按钮，返回键也能取消。

@module koplugin.book.features.passcode.pad
--]]

local Device = require("device")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Box = require("ui.themes.widgets.box")
local Button = require("ui.themes.widgets.button")
local Modal = require("ui.themes.widgets.modal")
local Text = require("ui.themes.widgets.text")
local Theme = require("ui.themes")
require("l10n").apply()
local _ = require("gettext")

local Screen = Device.screen

local KEYS = {
    { "1", "2", "3" },
    { "4", "5", "6" },
    { "7", "8", "9" },
    { "del", "0", "ok" },
}

---@class BookPasscodePad : BookThemeModal
---@field title string
---@field on_submit fun(pin: string): true|string
local Pad = Modal:extend{
    name = "book_passcode_pad",
    covers_fullscreen = true,
    title = nil,
    on_submit = nil,
}

Pad.MIN_LEN = 4
Pad.MAX_LEN = 6

function Pad:init()
    Modal.init(self)
    self.pin = ""
    self.message = nil
    self:updateView()
end

---@param key string 数字或 del / ok
function Pad:press(key)
    if key == "ok" then return self:submit() end
    if key == "del" then
        self.pin = self.pin:sub(1, -2)
    elseif #self.pin < Pad.MAX_LEN then
        self.pin = self.pin .. key
    end
    self.message = nil
    self:refresh()
end

function Pad:submit()
    local res = self.on_submit(self.pin)
    if res == true then return self:close() end
    self:clear(res)
end

--- 清空输入。
---@param message string|nil 清空后显示的提示
function Pad:clear(message)
    self.pin, self.message = "", message
    self:refresh()
end

function Pad:refresh()
    self:updateView()
    UIManager:setDirty(self, "ui")
end

--- 整屏窗口撤下后下层要整屏重画，墨水屏顺带清残影。
function Pad:close()
    Modal.close(self)
    UIManager:nextTick(function() UIManager:setDirty("all", "full") end)
end

---@param key string
---@param w number
---@param h number
---@return table
function Pad:key(key, w, h)
    local spec = { width = w, height = h, callback = function() self:press(key) end }
    if key == "del" then
        spec.icon, spec.variant, spec.enabled = "backspace", "ghost", #self.pin > 0
    elseif key == "ok" then
        spec.icon, spec.variant, spec.enabled = "check", "primary", #self.pin >= Pad.MIN_LEN
    else
        spec.text = key
    end
    return Button:new(spec)
end

function Pad:updateView()
    local t = self.theme
    local w, h = Screen:getWidth(), Screen:getHeight()
    local gap = Theme.px(t.space.md)
    local key_w = math.floor((math.min(w, h) * 0.7 - gap * 2) / 3)
    local key_h = math.floor(Theme.px(t.control.height) * 1.5)

    local col = VerticalGroup:new{
        align = "center",
        Text.line("title", self.title),
        VerticalSpan:new{ width = Theme.px(t.space.lg) },
        Text.line("hero", string.rep("●", #self.pin) .. string.rep("○", Pad.MAX_LEN - #self.pin)),
        VerticalSpan:new{ width = Theme.px(t.space.sm) },
        Text.line("caption", self.message or " ", { color = t.color.muted }),
        VerticalSpan:new{ width = Theme.px(t.space.lg) },
    }
    for _idx, keys in ipairs(KEYS) do
        local row = HorizontalGroup:new{}
        for i, key in ipairs(keys) do
            if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
            row[#row + 1] = self:key(key, key_w, key_h)
        end
        col[#col + 1] = row
        col[#col + 1] = VerticalSpan:new{ width = gap }
    end
    if self.dismissable then
        col[#col + 1] = Button:new{
            text = _("取消"), variant = "ghost", width = key_w,
            callback = function() self:close() end,
        }
    end
    self:setPanel(Box:new{ style = { bg = t.color.page }, width = w, height = h, col })
end

return Pad
