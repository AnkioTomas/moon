--[[-- 桌面设置项。
@module koplugin.book.desktop.pages.setting.desktop
--]]

local Row = require("ui.themes.widgets.row")
local Settings = require("utils.settings")
local _ = require("gettext")

---@class BookSettingsDesktop
local DesktopSettings = {}

---@param desktop table
---@param open_on boolean
---@return table
function DesktopSettings:rows(desktop, open_on)
    return {
        function(iw)
            return Row.widget({
                width = iw,
                icon = "visibility", title = _("启动打开桌面"),
                subtitle = _("KOReader 启动后直接进入月读"),
                toggle = open_on,
                callback = function()
                    require("menu").setOpenOnStart(not open_on)
                    desktop:updateView()
                end,
            })
        end,
        function(iw)
            local drawer_on = Settings.get("desktop").drawer_opens_desktop == true
            return Row.widget({
                width = iw,
                icon = "folder", title = _("抽屉图标打开桌面"),
                subtitle = _("启动打开桌面时，点击顶部菜单的抽屉图标回到月读"),
                toggle = drawer_on,
                callback = function()
                    Settings.get("desktop").drawer_opens_desktop = not drawer_on
                    Settings.save("desktop")
                    desktop:updateView()
                end,
            })
        end,
    }
end

return DesktopSettings
