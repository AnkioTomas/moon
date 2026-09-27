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
    ---@param _ctx BookQuickPanelContext|nil
    run = function(_ctx)
        require("nightmode").setLight(not require("utils.settings").get("display").auto_light)
    end,
}
