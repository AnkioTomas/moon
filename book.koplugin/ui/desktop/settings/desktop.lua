--[[-- 桌面设置项。
@module koplugin.book.ui.desktop.settings.desktop
--]]

local SettingRow = require("ui.components.settingrow")
local Host = require("host")
local _ = require("gettext")

---@class BookSettingsDesktop
local DesktopSettings = {}
DesktopSettings.__index = DesktopSettings

---@return BookSettingsDesktop
function DesktopSettings.new()
    return setmetatable({}, DesktopSettings)
end


---@param desktop table
---@param open_on boolean
---@return table
function DesktopSettings:rows(desktop, open_on)
    return {
        function(iw)
            return SettingRow.build(iw, {
                kind = "toggle", icon = "visibility", title = _("启动打开桌面"),
                subtitle = _("KOReader 启动后直接进入月读"),
                status = open_on and _("开") or _("关"), status_on = open_on,
                callback = function()
                    if open_on then G_reader_settings:saveSetting("start_with", "filemanager")
                    else G_reader_settings:saveSetting("start_with", Host.OPEN_ON_START_ID) end
                    desktop:updateView()
                end,
            })
        end,
    }
end

return DesktopSettings
