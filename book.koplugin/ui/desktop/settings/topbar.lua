--[[-- 顶部状态栏设置。
@module koplugin.book.ui.desktop.settings.topbar
--]]

local SettingRow = require("ui.components.settingrow")
local MoonSettings = require("utils.settings")
local _ = require("gettext")

---@class BookSettingsTopbar
local TopbarSettings = {}

-- 预览样例跟着真顶栏：左时钟/源，右指标。wifi 只有图标。
local ITEMS = {
    { id = "clock", label = _("时钟"), icon = "schedule", align = "left", sample = "12:34", bar_icon = false },
    { id = "source", label = _("数据源"), icon = "source", align = "left", sample = _("本地") },
    { id = "memory", label = _("剩余内存"), icon = "memory", sample = "128M" },
    { id = "cache", label = _("缓存任务"), icon = "download", sample = "1/3" },
    { id = "storage", label = _("剩余存储"), icon = "hard_drive", sample = "2.1G" },
    { id = "wifi", label = _("Wi-Fi"), icon = "wifi", icon_only = true },
    { id = "brightness", label = _("亮度"), icon = "brightness_6", sample = "40%" },
    { id = "battery", label = _("电池"), icon = "battery_android_full", sample = "85%" },
}

---@param desktop table
---@return table
function TopbarSettings:rows(desktop)
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
                    if desktop.onEvent then desktop:onEvent("topbar_changed") end
                    desktop:updateView()
                end,
            })
        end
    end
    return rows
end

--- 已启用项按真顶栏左右分栏。
---@param width number
---@return table
function TopbarSettings.preview(width)
    local Overlay = require("ui.desktop.settings.overlay")
    local Blitbuffer = require("ffi/blitbuffer")
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local Icon = require("ui.components.icon")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local OverlapGroup = require("ui/widget/overlapgroup")
    local RightContainer = require("ui/widget/container/rightcontainer")
    local TextWidget = require("ui/widget/textwidget")
    local UI = require("ui.components.bookui")
    local home = MoonSettings.get("home")
    local config = type(home.home_topbar_items) == "table" and home.home_topbar_items or {}
    local bar_h = UI.sz(40)
    local left = HorizontalGroup:new{ align = "center" }
    local right = HorizontalGroup:new{ align = "center" }
    local gap = UI.sz(8)
    local n_left, n_right = 0, 0
    for _idx, item in ipairs(ITEMS) do
        if config[item.id] ~= false then
            local widget
            if item.icon_only then
                widget = Icon.widget{ name = item.icon, size = 14 }
            elseif item.bar_icon == false then
                widget = TextWidget:new{
                    text = item.sample,
                    face = UI.face("xx_smallinfofont", 12),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
            else
                widget = Icon.label{
                    name = item.icon,
                    text = item.sample,
                    size = 14,
                    font_size = 12,
                    gap = UI.sz(3),
                }
            end
            if widget then
                local group = item.align == "left" and left or right
                local n = item.align == "left" and n_left or n_right
                if n > 0 then table.insert(group, HorizontalSpan:new{ width = gap }) end
                table.insert(group, widget)
                if item.align == "left" then
                    n_left = n + 1
                else
                    n_right = n + 1
                end
            end
        end
    end
    if n_left + n_right == 0 then
        return Overlay.previewPlaceholder(width, bar_h, _("无"))
    end
    local pad = UI.sz(8)
    local inner_w = math.max(1, width - 2)
    local inner_h = math.max(1, bar_h - 2)
    return Overlay.previewBox(width, OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = inner_h },
        LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = pad },
                left,
            },
        },
        RightContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            HorizontalGroup:new{
                right,
                HorizontalSpan:new{ width = pad },
            },
        },
    }, bar_h)
end

return TopbarSettings
