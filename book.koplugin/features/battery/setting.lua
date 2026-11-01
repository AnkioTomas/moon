--[[--
电池页：挂在「我的设备 → 本机」里，点进去才是这一页。没有配置项，读数在 page.lua。

@module koplugin.book.features.battery.setting
--]]

local _ = require("gettext")

local Setting = {}

---@param _desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(_desktop)
    return {}
end

require("utils.extension").add("setting.device_section", {
    id = "battery",
    icon = "battery_android_full",
    title = _("电池"),
    refresh_seconds = 15,
    sections = function() return require("features.battery.page").sections() end,
})

return Setting
