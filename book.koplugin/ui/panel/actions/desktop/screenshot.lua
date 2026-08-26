--[[-- 截屏快捷动作。
@module koplugin.book.ui.panel.actions.desktop.screenshot
--]]

local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "screenshot",
    title = _("截屏"),
    icon = "photo_camera",
    scope = "desktop",
    --- 面板已在 executeAction 里关闭；此处等重绘完成再截屏。
    ---@param _ctx BookQuickPanelContext|nil
    ---@return void
    run = function(_ctx)
        UIManager:forceRePaint()
        if Device:hasEinkScreen() then
            UIManager:waitForVSync()
        end
        UIManager:sendEvent(Event:new("Screenshot"))
    end,
}
