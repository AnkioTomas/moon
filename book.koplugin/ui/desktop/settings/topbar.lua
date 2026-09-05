--[[-- 顶部状态栏设置。
@module koplugin.book.ui.desktop.settings.topbar
--]]

local SettingRow = require("ui.components.settingrow")
local MoonSettings = require("utils.settings")
local _ = require("gettext")

local TopbarSettings = {}

local ITEMS = {
    { id = "clock", label = _("时钟"), icon = "schedule" },
    { id = "source", label = _("数据源"), icon = "source" },
    { id = "memory", label = _("剩余内存"), icon = "memory" },
    { id = "cache", label = _("缓存任务"), icon = "download" },
    { id = "storage", label = _("剩余存储"), icon = "hard_drive" },
    { id = "wifi", label = _("Wi-Fi"), icon = "wifi" },
    { id = "brightness", label = _("亮度"), icon = "brightness_6" },
    { id = "battery", label = _("电池"), icon = "battery_android_full" },
}

---@param desktop table
---@return table
function TopbarSettings.rows(desktop)
    local home = MoonSettings.get("home")
    local config = type(home.home_topbar_items) == "table" and home.home_topbar_items or {}
    local rows = {}
    for _idx, item in ipairs(ITEMS) do
        local enabled = config[item.id] ~= false
        rows[#rows + 1] = function(iw)
            return SettingRow.build(iw, {
                kind = "toggle",
                icon = item.icon,
                title = item.label,
                status = enabled and _("开") or _("关"),
                status_on = enabled,
                callback = function()
                    if type(home.home_topbar_items) ~= "table" then
                        home.home_topbar_items = {}
                    end
                    home.home_topbar_items[item.id] = not enabled
                    MoonSettings.saveSection("home", home)
                    desktop:rebuild()
                end,
            })
        end
    end
    return rows
end

return TopbarSettings
