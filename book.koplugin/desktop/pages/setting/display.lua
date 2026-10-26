--[[-- 外观（风格 / 字体 / 缩放 / 遮罩）与屏幕（刷新 / 彩屏）设置项。
@module koplugin.book.desktop.pages.setting.display
--]]

local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local List = require("ui.themes.widgets.list")
local Spin = require("ui.themes.widgets.spin")
local Toast = require("ui.themes.widgets.toast")
local Row = require("ui.themes.widgets.row")
local FontPicker = require("ui.widgets.fontpicker")
local Theme = require("ui.themes")
local MoonSettings = require("utils.settings")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookSettingsDisplay
local Display = {}
local STYLE_NAMES = {
    paper = _("纸本"),
    bold = _("高对比"),
    soft = _("柔和"),
}
local COLOR_PRESETS = {
    { value = 0x0756AD, text = _("蓝色") },
    { value = 0x00734F, text = _("绿色") },
    { value = 0x7038A0, text = _("紫色") },
    { value = 0xB32635, text = _("红色") },
    { value = 0xAD4C00, text = _("橙色") },
}
local REFRESH_PRESETS = {
    { value = 0, text = _("从不") },
    { value = 1, text = _("每页") },
    { value = 6, text = _("每 6 页") },
    { value = -1, text = _("每章") },
}
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

---@param rate number|nil
---@return string
local function refreshRateLabel(rate)
    rate = tonumber(rate)
    if rate == nil then return _("每 6 页") end
    for _idx, item in ipairs(REFRESH_PRESETS) do
        if item.value == rate then return item.text end
    end
    if rate < 0 then return _("每章") end
    return T(_("每 %1 页"), rate)
end

---@param desktop table
---@return (fun(width: number): table|nil)|nil
local function refreshRow(desktop)
    if not Device:hasEinkScreen() then return nil end
    return function(iw)
        local day = select(1, UIManager:getRefreshRate())
        return Row.widget({
            width = iw,
            kind = "nav", icon = "autorenew", title = _("屏幕刷新"),
            subtitle = _("墨水屏全刷间隔；翻页动画开启时默认改为从不"),
            status = refreshRateLabel(day), status_on = true,
            callback = function()
                List:new{
                    title = _("屏幕刷新"),
                    items = REFRESH_PRESETS,
                    current = day,
                    centered = true,
                    on_select = function(value)
                        UIManager:setRefreshRate(value, value)
                        desktop:updateView()
                    end,
                }:show()
            end,
        })
    end
end

---@param desktop table
---@return (fun(width: number): table|nil)|nil
local function colorRow(desktop)
    local Screen = Device.screen
    local can_color = Screen.isColorScreen and Screen:isColorScreen()
        or Device.hasColorScreen and Device:hasColorScreen()
        or Screen.isColorEnabled and Screen:isColorEnabled()
    if not can_color then return nil end
    return function(iw)
        local color_on = Screen.isColorEnabled and Screen:isColorEnabled()
            or G_reader_settings:isTrue("color_rendering")
        return Row.widget({
            width = iw,
            icon = "palette", title = _("彩色屏幕支持"),
            subtitle = _("在彩屏上启用彩色渲染"),
            toggle = color_on,
            callback = function()
                local new_val = not color_on
                G_reader_settings:saveSetting("color_rendering", new_val)
                require("document/canvascontext"):setColorRenderingEnabled(new_val)
                UIManager:broadcastEvent(Event:new("ColorRenderingUpdate"))
                desktop:updateView()
                if Device:isKobo() and Device:hasColorScreen() then
                    UIManager:askForRestart()
                end
            end,
        })
    end
end

---@param ctx table
---@return table
function Display:appearanceRows(ctx)
    local desktop = ctx.desktop
    local font_name, scale = ctx.font_name, ctx.scale
    return {
        function(iw)
            local id = Theme.id()
            return Row.widget({
                width = iw,
                kind = "nav", icon = "style", title = _("界面风格"),
                subtitle = _("纸本细线、高对比粗边，或柔和圆角"),
                status = STYLE_NAMES[id], status_on = true,
                callback = function()
                    local items = {}
                    for _idx, style_id in ipairs(Theme.ids) do
                        items[#items + 1] = { value = style_id, text = STYLE_NAMES[style_id] }
                    end
                    List:new{
                        title = _("界面风格"),
                        items = items,
                        current = id,
                        centered = true,
                        on_select = function(value)
                            Theme.set(value)
                            desktop:updateView()
                        end,
                    }:show()
                end,
            })
        end,
        function(iw)
            return Row.widget({
                width = iw,
                kind = "nav", icon = "text_fields", title = _("界面字体"),
                subtitle = _("替换 KOReader 界面字体，不影响书籍正文"),
                status = font_name, status_on = true,
                callback = function()
                    FontPicker.open{ title = _("界面字体"), on_done = function()
                        require("ui.fonts").applyCurrent()
                        desktop:updateView()
                    end }
                end,
            })
        end,
        function(iw)
            local conf = MoonSettings.get("ui")
            return Row.widget({
                width = iw,
                icon = "format_bold", title = _("字体加粗"),
                subtitle = _("界面文字加粗，觉得字偏灰时打开，不影响书籍正文"),
                toggle = conf.font_bold,
                callback = function()
                    conf.font_bold = not conf.font_bold
                    MoonSettings.save("ui", conf)
                    desktop:updateView()
                end,
            })
        end,
        function(iw)
            return Row.widget({
                width = iw,
                kind = "nav", icon = "format_size", title = _("界面缩放"),
                subtitle = _("调整月读界面的整体大小"),
                status = string.format("%d%%", scale), status_on = true,
                callback = function()
                    Spin:new{
                        title = _("界面缩放"),
                        fields = { { value = Theme.scale(), min = Theme.SCALE_MIN, max = Theme.SCALE_MAX,
                            step = Theme.SCALE_STEP, format = function(v) return v .. "%" end } },
                        callback = function(v)
                            local n = Theme.setScale(v)
                            Toast:new{ text = string.format("%d%%", n), timeout = 1.5 }:show()
                            desktop:updateView()
                        end,
                    }:show()
                end,
            })
        end,
        function(iw)
            local conf = MoonSettings.get("ui")
            return Row.widget({
                width = iw,
                icon = "texture", title = _("背景遮罩"),
                subtitle = _("弹出面板和菜单时用网点压暗背景"),
                toggle = conf.mesh_mask,
                callback = function()
                    conf.mesh_mask = not conf.mesh_mask
                    MoonSettings.save("ui", conf)
                    desktop:updateView()
                end,
            })
        end,
        function(iw)
            local conf = MoonSettings.get("ui")
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
                            MoonSettings.save("ui", conf)
                        end,
                    }:show()
                end,
            })
        end,
        function(iw)
            local conf = MoonSettings.get("ui")
            return Row.widget({
                width = iw,
                icon = "label", title = _("底部导航名称"),
                subtitle = _("关闭后仅显示图标"),
                toggle = conf.tabbar_labels ~= false,
                callback = function()
                    conf.tabbar_labels = not (conf.tabbar_labels ~= false)
                    MoonSettings.save("ui", conf)
                    desktop:updateView()
                end,
            })
        end,
        function(iw)
            local conf = MoonSettings.get("ui")
            local value = conf.theme_color or COLOR_PRESETS[1].value
            local label = string.format("#%06X", value)
            for _idx, preset in ipairs(COLOR_PRESETS) do
                if preset.value == value then label = preset.text break end
            end
            return Row.widget({
                width = iw,
                kind = "nav", icon = "palette", title = _("主题色"),
                subtitle = _("彩色模式下统一用于图标、按钮和统计"),
                status = label, status_on = true,
                callback = function()
                    List:new{
                        title = _("主题色"), items = COLOR_PRESETS,
                        current = value, centered = true,
                        on_select = function(color)
                            conf.theme_color = color
                            MoonSettings.save("ui", conf)
                            desktop:updateView()
                        end,
                    }:show()
                end,
            })
        end,
    }
end

--- 墨水屏刷新与彩屏条件行；夜间与亮度在 nightmode feature。
---@param ctx table
---@return table
function Display:screenRows(ctx)
    local rows = {}
    local desktop = ctx.desktop
    local refresh = refreshRow(desktop)
    if refresh then rows[#rows + 1] = refresh end
    local color = colorRow(desktop)
    if color then rows[#rows + 1] = color end
    return rows
end

return Display
