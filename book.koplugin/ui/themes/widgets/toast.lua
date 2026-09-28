--[[--
主题提示（替代 InfoMessage）：一段文字，点任意处或 timeout 秒后收起。

  +----------------------+
  | 已加入书架           |
  +----------------------+

  Toast:new{ text = "已加入书架", timeout = 2 }:show()

@module koplugin.book.ui.themes.widgets.toast
--]]

local UIManager = require("ui/uimanager")
local Modal = require("ui.themes.widgets.modal")
local Text = require("ui.themes.widgets.text")

---@class BookThemeToast : BookThemeModal
---@field text string
---@field timeout number|nil 秒；nil 不自动收起
local Toast = Modal:extend{
    close_on_tap = true,
    text = nil,
    timeout = nil,
}

function Toast:init()
    Modal.init(self)
    local t = self.theme
    self:setDialog{ body = Text.box(t, "body", self.text, self:innerWidth(), { bg = t.dialog.bg }) }
end

function Toast:onShow()
    if not self.timeout then return end
    self._timer = function() self:close() end
    UIManager:scheduleIn(self.timeout, self._timer)
end

function Toast:onCloseWidget()
    if self._timer then
        UIManager:unschedule(self._timer)
        self._timer = nil
    end
    Modal.onCloseWidget(self)
end

return Toast
