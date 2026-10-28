--[[-- 桌面设置项（启动与按键、分页与弹窗）。
@module koplugin.book.desktop.pages.setting.desktop
--]]

local List = require("ui.themes.widgets.list")
local Row = require("ui.themes.widgets.row")
local Settings = require("utils.settings")
local _ = require("gettext")

local SWIPE_DISMISS_PRESETS = {
    { value = "down", text = _("下滑") },
    { value = "up", text = _("上滑") },
    { value = "off", text = _("关闭") },
}

---@param mode string|nil
---@return string
local function swipeDismissLabel(mode)
    for _idx, item in ipairs(SWIPE_DISMISS_PRESETS) do
        if item.value == mode then return item.text end
    end
    return SWIPE_DISMISS_PRESETS[1].text
end

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

---@param desktop table
---@return table
function DesktopSettings:inputRows(desktop)
    local rows = {}
    for _idx, spec in ipairs({
        { key = "pager_keys", title = _("分页按键"), subtitle = _("使用物理按键或蓝牙翻页键翻动当前窗口") },
        { key = "pager_swipe", title = _("滑动分页"), subtitle = _("左右滑动翻页，桌面优先执行自定义手势") },
        { key = "pager_cycle", title = _("循环分页"), subtitle = _("首页与末页相连；未加载完整的列表不循环"), default = false },
        { key = "modal_keys", title = _("返回键关闭弹窗"), subtitle = _("使用物理或蓝牙返回键关闭最上层弹窗") },
    }) do
        rows[#rows + 1] = function(iw)
            local conf = Settings.get("ui")
            local enabled = conf[spec.key]
            if enabled == nil then enabled = spec.default ~= false end
            return Row.widget({
                width = iw, icon = "touch_app", title = spec.title, subtitle = spec.subtitle,
                toggle = enabled,
                callback = function()
                    conf[spec.key] = not enabled
                    Settings.save("ui", conf)
                    desktop:updateView()
                end,
            })
        end
    end
    rows[#rows + 1] = function(iw)
        local conf = Settings.get("ui")
        return Row.widget({
            width = iw,
            kind = "nav", icon = "swipe", title = _("弹窗关闭手势"),
            subtitle = _("上滑或下滑关闭弹出的面板和菜单"),
            status = swipeDismissLabel(conf.swipe_dismiss), status_on = true,
            callback = function()
                List:new{
                    title = _("弹窗关闭手势"),
                    items = SWIPE_DISMISS_PRESETS,
                    current = conf.swipe_dismiss,
                    centered = true,
                    on_select = function(value)
                        conf.swipe_dismiss = value
                        Settings.save("ui", conf)
                    end,
                }:show()
            end,
        })
    end
    return rows
end

--- 照抄 DeviceListener:onSwapPageTurnButtons() 的全局分支：先撤销单侧反转，再整体翻转。
---@param device table
---@param gs table G_reader_settings
function DesktopSettings.swapPageKeys(device, gs)
    for _idx, side in ipairs({ "Left", "Right" }) do
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
