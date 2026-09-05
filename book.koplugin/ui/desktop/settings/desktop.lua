--[[-- 桌面设置项。
@module koplugin.book.ui.desktop.settings.desktop
--]]

local Base = require("ui.desktop.home.components.base")
local SettingRow = require("ui.components.settingrow")
local Host = require("host")
local _ = require("gettext")
local T = require("ffi/util").template

local DesktopSettings = {}

---@param desktop table
---@param open_on boolean
---@return table
function DesktopSettings.rows(desktop, open_on)
    local count = #Base.enabledLayout()
    return {
        function(iw)
            return SettingRow.build(iw, {
                kind = "toggle", icon = "visibility", title = _("启动打开桌面"),
                status = open_on and _("开") or _("关"), status_on = open_on,
                callback = function()
                    if open_on then G_reader_settings:saveSetting("start_with", "filemanager")
                    else G_reader_settings:saveSetting("start_with", Host.OPEN_ON_START_ID) end
                    desktop:rebuild()
                end,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "home", title = _("首页布局"),
                status = T(_("已启用 %1 项"), count), status_on = count > 0,
                callback = function()
                    desktop:showSettingsSub("home", "desktop")
                end,
            })
        end,
    }
end

return DesktopSettings
