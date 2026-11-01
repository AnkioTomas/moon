--[[--
电池设置入口：系统组「电池」。没有配置项，读数在 page.lua。

@module koplugin.book.features.battery.setting
--]]

local _ = require("gettext")

local Setting = {}

---@param _desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(_desktop)
    return {
        {
            id = "main",
            group = "system",
            order = 55,
            icon = "battery_android_full",
            title = _("电池"),
            subtitle = _("健康度、循环次数与充放电"),
            page = {
                title = _("电池"),
                refresh_seconds = 15,
                sections = function() return require("features.battery.page").sections() end,
            },
        },
    }
end

return Setting
