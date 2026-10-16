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
    local rows = {
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
    -- 纯触屏设备没有翻页键，不显示。
    if require("device"):hasKeys() then
        rows[#rows + 1] = function(iw)
            local keys_on = Settings.get("desktop").page_keys ~= false
            return Row.widget({
                width = iw,
                icon = "swap_horiz", title = _("桌面物理翻页键"),
                subtitle = _("用侧键或音量键翻图书馆、书城、首页、统计的页"),
                toggle = keys_on,
                callback = function()
                    Settings.get("desktop").page_keys = not keys_on
                    Settings.save("desktop")
                    desktop:updateView()
                end,
            })
        end
        -- 与 KOReader「反转翻页键」同一设置与 Device:invertButtons()，桌面/阅读器共用 event_map。
        rows[#rows + 1] = function(iw)
            local inverted = G_reader_settings:isTrue("input_invert_page_turn_keys")
            return Row.widget({
                width = iw,
                icon = "swap_vert", title = _("反转翻页键"),
                subtitle = _("交换前进与后退键，与 KOReader 设置同步"),
                toggle = inverted,
                callback = function()
                    DesktopSettings.swapPageKeys(require("device"), G_reader_settings)
                    desktop:updateView()
                end,
            })
        end
    end
    return rows
end

--- 照抄 DeviceListener:onSwapPageTurnButtons() 的全局分支：先撤销单侧反转，再整体翻转。
---@param device table
---@param gs table G_reader_settings
function DesktopSettings.swapPageKeys(device, gs)
    for _, side in ipairs({ "Left", "Right" }) do
        local key = "input_invert_" .. side:lower() .. "_page_turn_keys"
        if gs:isTrue(key) then
            gs:makeFalse(key)
            device["invertButtons" .. side](device)
        end
    end
    gs:flipNilOrFalse("input_invert_page_turn_keys")
    device:invertButtons()
end

return DesktopSettings
