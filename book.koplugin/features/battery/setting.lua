--[[--
电池页：挂在「我的设备 → 本机」里，点进去才是这一页。
用法统计累计落在本分区；读数在 page.lua / stats.lua。

@module koplugin.book.features.battery.setting
--]]

local _ = require("gettext")

local Setting = {}

-- 四桶累计（percentage=Δ% 绝对值之和，time=秒）；状态键无默认值，首次 ensure 现采。
Setting.defaults = {
    awake = { percentage = 0, time = 0 },
    sleeping = { percentage = 0, time = 0 },
    charging = { percentage = 0, time = 0 },
    discharging = { percentage = 0, time = 0 },
}
Setting.keys = { "awake_state", "charging_state", "was_charging" }

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
    docs = "/manual/device/battery",
    status = function()
        local result = require("features.battery.probe").read()
        if not result.supported or not result.reading then return _("不支持") end
        return string.format("%.1f%%", result.reading.health_pct)
    end,
    refresh_seconds = 15,
    sections = function(desktop) return require("features.battery.page").sections(desktop) end,
})

return Setting
