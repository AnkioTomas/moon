--[[-- 截屏快捷动作。
@module koplugin.book.features.panel.actions.desktop.screenshot
--]]

local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local function capture()
    UIManager:forceRePaint()
    if Device:hasEinkScreen() then
        UIManager:waitForVSync()
    end
    UIManager:sendEvent(Event:new("Screenshot"))
end

-- 长按的延时：留出时间切到要截的界面；提示在截屏前消失。
local DELAY, TOAST = 3, 2

---@type BookQuickPanelAction
return {
    id = "screenshot",
    title = _("截屏"),
    icon = "photo_camera",
    scope = "desktop",
    --- 面板已在 executeAction 里关闭；此处等重绘完成再截屏。
    run = capture,
    --- 长按：延时截屏，方便截弹窗、菜单。
    hold = function()
        require("ui.themes.widgets.toast"):new{ text = _("3 秒后截屏"), timeout = TOAST }:show()
        UIManager:scheduleIn(DELAY, capture)
    end,
}
