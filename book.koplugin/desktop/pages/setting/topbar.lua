--[[-- 顶部状态栏设置。
@module koplugin.book.desktop.pages.setting.topbar
--]]

local Row = require("ui.themes.widgets.row")
local MoonSettings = require("utils.settings")
local _ = require("gettext")

---@class BookSettingsTopbar
local TopbarSettings = {}

-- 预览样例跟着真顶栏：左时钟/源，右指标。bar_icon 是顶栏上画的图标（时钟不画，wifi 只有图标）。
local ITEMS = {
    { id = "clock", label = _("时钟"), icon = "schedule", align = "left", sample = "12:34" },
    { id = "source", label = _("数据源"), icon = "source", align = "left", sample = _("本地"), bar_icon = "source" },
    { id = "memory", label = _("剩余内存"), icon = "memory", sample = "128M", bar_icon = "memory" },
    { id = "cache", label = _("后台任务"), icon = "download", sample = "1/3", bar_icon = "download" },
    { id = "storage", label = _("剩余存储"), icon = "hard_drive", sample = "2.1G", bar_icon = "hard_drive" },
    { id = "wifi", label = _("Wi-Fi"), icon = "wifi", bar_icon = "wifi" },
    { id = "brightness", label = _("亮度"), icon = "brightness_6", sample = "40%", bar_icon = "brightness_6" },
    { id = "battery", label = _("电池"), icon = "battery_android_full", sample = "85%", bar_icon = "battery_android_full" },
}

---@param desktop table
---@return table
function TopbarSettings:rows(desktop)
    local home = MoonSettings.get("desktop")
    local config = home.home_topbar_items
    local rows = {}
    for _idx, item in ipairs(ITEMS) do
        local enabled = config[item.id] ~= false
        rows[#rows + 1] = function(iw)
            return Row.widget({
                width = iw,
                icon = item.icon,
                title = item.label,
                toggle = enabled,
                callback = function()
                    config[item.id] = not enabled
                    MoonSettings.save("desktop", home)
                    desktop:onEvent("topbar_changed")
                    desktop:updateView()
                end,
            })
        end
    end
    return rows
end

--- 已启用项按真顶栏左右分栏（同一套 TopBar.metric / TopBar.row）。
---@param width number
---@return table
function TopbarSettings.preview(width)
    local Overlay = require("desktop.pages.setting.overlay")
    local TopBar = require("desktop.topbar")
    local bar_h = TopBar.height()
    local left, right = {}, {}
    for _idx, item in ipairs(ITEMS) do
        if TopBar.visible(item.id) then
            local side = item.align == "left" and left or right
            side[#side + 1] = TopBar.metric(item.sample, item.bar_icon)
        end
    end
    if #left + #right == 0 then
        return Overlay.previewPlaceholder(width, bar_h, _("无"))
    end
    return Overlay.previewBox(width, TopBar.row(math.max(1, width - 2), math.max(1, bar_h - 2), left, right), bar_h)
end

return TopbarSettings
