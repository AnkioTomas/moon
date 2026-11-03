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
    order = 30,
    icon = "battery_android_full",
    title = _("电池"),
    status = function()
        local result = require("features.battery.probe").read()
        if not result.supported or not result.reading then return _("不支持") end
        local pct = result.reading.health_pct
        return pct and string.format("%.1f%%", pct) or _("无法判断")
    end,
    refresh_seconds = 15,
    sections = function() return require("features.battery.page").sections() end,
})

return Setting
