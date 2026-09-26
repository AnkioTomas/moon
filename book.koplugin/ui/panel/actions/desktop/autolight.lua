--[[-- 自动亮度开关快捷动作。
@module koplugin.book.ui.panel.actions.desktop.autolight
--]]

local Device = require("device")
local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "autolight",
    title = _("自动亮度"),
    icon = "brightness_auto",
    scope = "desktop",
    keep_open = true,
    ---@return boolean
    available = function()
        return Device:hasFrontlight()
    end,
    ---@return boolean
    active = function()
        return require("utils.settings").get("display").auto_light == true
    end,
    --- 切换自动亮度；开了却不会生效时提示去开自动夜间模式。
    ---@param _ctx BookQuickPanelContext|nil
    run = function(_ctx)
        local NightMode = require("nightmode")
        NightMode.setLight(not require("utils.settings").get("display").auto_light)
        if NightMode.lightIdle() then
            local UIManager = require("ui/uimanager")
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("没有光线传感器，亮度跟随自动夜间模式的昼夜时间切换，请同时开启自动夜间模式。"),
            })
        end
    end,
}
