--[[-- 显示设置项。
@module koplugin.book.ui.desktop.settings.display
--]]

local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Popup = require("ui.views.popup")
local SettingRow = require("ui.components.settingrow")
local FontPicker = require("ui.components.fontpicker")
local UI = require("ui.components.bookui")
local MoonSettings = require("utils.settings")
local NightMode = require("nightmode")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookSettingsDisplay
local Display = {}
local REFRESH_PRESETS = {
    { value = 0, text = _("从不") },
    { value = 1, text = _("每页") },
    { value = 6, text = _("每 6 页") },
    { value = -1, text = _("每章") },
}

---@param rate number|nil
---@return string
local function refreshRateLabel(rate)
    rate = tonumber(rate)
    if rate == nil then return _("每 6 页") end
    for _, item in ipairs(REFRESH_PRESETS) do
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
        return SettingRow.build(iw, {
            kind = "nav", icon = "autorenew", title = _("屏幕刷新"),
            subtitle = _("墨水屏全刷间隔；翻页动画开启时默认改为从不"),
            status = refreshRateLabel(day), status_on = true,
            callback = function()
                local items = {}
                for _, preset in ipairs(REFRESH_PRESETS) do
                    items[#items + 1] = {
                        text = day == preset.value and "✓ " .. preset.text or preset.text,
                        value = preset.value,
                    }
                end
                Popup.sheet{
                    title = _("屏幕刷新"),
                    items = items,
                    on_select = function(value)
                        UIManager:setRefreshRate(value, value)
                        desktop:updateView()
                    end,
                }
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
        return SettingRow.build(iw, {
            kind = "toggle", icon = "palette", title = _("彩色屏幕支持"),
            subtitle = _("在彩屏上启用彩色渲染"),
            status = color_on and _("开") or _("关"), status_on = color_on,
            callback = function()
                local new_val = not color_on
                G_reader_settings:saveSetting("color_rendering", new_val)
                local ok_canvas, CanvasContext = pcall(require, "document/canvascontext")
                if ok_canvas and CanvasContext.setColorRenderingEnabled then
                    CanvasContext:setColorRenderingEnabled(new_val)
                end
                UIManager:broadcastEvent(Event:new("ColorRenderingUpdate"))
                desktop:updateView()
                if Device:isKobo() and Device:hasColorScreen() then
                    UIManager:askForRestart()
                end
            end,
        })
    end
end

---@param minute number
---@return string
local function clock(minute)
    return string.format("%02d:%02d", math.floor(minute / 60), minute % 60)
end

--- 应用模式并报今天的开关时间；KOReader 自带的自动夜间模式也开着时提醒，两者会互相覆盖。
---@param desktop table
---@param mode "off"|"schedule"|"sun"
---@param head string|nil 首行提示
local function applyNight(desktop, mode, head)
    NightMode.setMode(mode)
    desktop:updateView()
    if mode == "off" then return end
    local from, to = NightMode.window()
    local lines = { head }
    lines[#lines + 1] = T(_("夜间模式将在 %1 开启，%2 关闭"), clock(from), clock(to))
    if (G_reader_settings:readSetting("autowarmth_activate") or 0) ~= 0 then
        lines[#lines + 1] = _("KOReader 自带的自动夜间模式也开着，两者会互相覆盖，建议关掉其中一个。")
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n\n") })
end

--- 依次选夜间开始、结束时间。
---@param desktop table
local function pickSchedule(desktop)
    local DateTimeWidget = require("ui/widget/datetimewidget")
    local conf = MoonSettings.get("display")
    local function pick(title, minute, ok_text, done)
        UIManager:show(DateTimeWidget:new{
            title_text = title, ok_text = ok_text,
            hour = math.floor(minute / 60), min = minute % 60,
            callback = function(t) done(t.hour * 60 + t.min) end,
        })
    end
    pick(_("夜间开始"), conf.auto_night_from, _("下一步"), function(from)
        pick(_("夜间结束"), conf.auto_night_to, _("保存"), function(to)
            conf.auto_night_from, conf.auto_night_to = from, to
            applyNight(desktop, "schedule")
        end)
    end)
end

--- 定位成功才切到日出日落；失败保持原模式。
---@param desktop table
local function pickSun(desktop)
    local loading = InfoMessage:new{ text = _("正在定位…") }
    UIManager:show(loading)
    NightMode.locate(function(ok, city)
        UIManager:close(loading)
        if not ok then
            UIManager:show(InfoMessage:new{ text = _("定位失败，请联网后重试"), timeout = 3 })
            return
        end
        applyNight(desktop, "sun", T(_("已定位：%1"), city or _("当前位置")))
    end)
end

---@param desktop table
---@return fun(width: number): table
local function nightRow(desktop)
    return function(iw)
        local mode = MoonSettings.get("display").auto_night
        local from, to = NightMode.window()
        return SettingRow.build(iw, {
            kind = "nav", icon = "dark_mode", title = _("自动夜间模式"),
            subtitle = _("定时或按日出日落切换；中途手动切换不会被立刻改回"),
            status = from and clock(from) .. "–" .. clock(to) or _("关"), status_on = from ~= nil,
            callback = function()
                local items = {}
                for _, preset in ipairs({
                    { value = "off", text = _("关闭") },
                    { value = "schedule", text = _("定时") },
                    { value = "sun", text = _("日出日落") },
                }) do
                    items[#items + 1] = {
                        text = mode == preset.value and "✓ " .. preset.text or preset.text,
                        value = preset.value,
                    }
                end
                Popup.sheet{
                    title = _("自动夜间模式"),
                    items = items,
                    on_select = function(value)
                        if value == "schedule" then return pickSchedule(desktop) end
                        if value == "sun" then return pickSun(desktop) end
                        applyNight(desktop, "off")
                    end,
                }
            end,
        })
    end
end

-- 与 Device:ambientBrightnessLevel() 的 0..4 一一对应。
local LEVEL_NAMES = { _("黑暗"), _("昏暗"), _("中性"), _("明亮"), _("刺眼") }

---@param percent number
---@return string
local function lightLabel(percent)
    return percent > 0 and percent .. "%" or _("关灯")
end

--- 自动亮度菜单：开关 + 各档（有传感器）或白天 / 夜间（无传感器）亮度。
---@param desktop table
local function openLight(desktop)
    local conf = MoonSettings.get("display")
    local function save()
        MoonSettings.saveSection("display", conf)
        NightMode.applyLight()
        desktop:updateView()
    end
    local items = { { text = conf.auto_light and _("关闭") or _("开启"), value = "toggle" } }
    local function add(name, tbl, key)
        items[#items + 1] = { text = name .. "  " .. lightLabel(tbl[key]), value = "edit", name = name, tbl = tbl, key = key }
    end
    if NightMode.hasSensor() then
        for i, name in ipairs(LEVEL_NAMES) do add(name, conf.auto_light_levels, i) end
    else
        add(_("白天"), conf, "auto_light_day")
        add(_("夜间"), conf, "auto_light_night")
    end
    Popup.sheet{
        title = _("自动亮度"),
        items = items,
        on_select = function(value, item)
            if value == "edit" then
                return Popup.spin{
                    title = item.name, value = item.tbl[item.key],
                    value_min = 0, value_max = 100, value_step = 1, value_hold_step = 5,
                    unit = "%", ok_always_enabled = true,
                    callback = function(spin)
                        item.tbl[item.key] = spin.value
                        save()
                    end,
                }
            end
            NightMode.setLight(not conf.auto_light)
            desktop:updateView()
            if NightMode.lightIdle() then
                UIManager:show(InfoMessage:new{
                    text = _("没有光线传感器，亮度跟随自动夜间模式的昼夜时间切换，请同时开启自动夜间模式。"),
                })
            end
        end,
    }
end

---@param desktop table
---@return (fun(width: number): table)|nil
local function lightRow(desktop)
    if not Device:hasFrontlight() then return nil end
    return function(iw)
        local on = MoonSettings.get("display").auto_light
        return SettingRow.build(iw, {
            kind = "nav", icon = "brightness_auto", title = _("自动亮度"),
            subtitle = NightMode.hasSensor() and _("按环境光调节；光线变化时才会覆盖手动调节")
                or _("跟随自动夜间模式的昼夜时间切换"),
            status = on and _("开") or _("关"), status_on = on,
            callback = function() openLight(desktop) end,
        })
    end
end

---@param ctx table
---@return table
function Display:rows(ctx)
    local desktop = ctx.desktop
    local font_name, scale, grid_max_cols = ctx.font_name, ctx.scale, ctx.grid_max_cols
    local rows = {
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "text_fields", title = _("界面字体"),
                subtitle = _("只影响月读界面，不影响书籍正文"),
                status = font_name, status_on = true,
                callback = function()
                    FontPicker.open{ title = _("界面字体"), on_done = function()
                        require("utils.font").applyCurrent()
                        desktop:updateView()
                    end }
                end,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "format_size", title = _("界面缩放"),
                subtitle = _("调整月读界面的整体大小"),
                status = string.format("%d%%", scale), status_on = true,
                callback = function()
                    Popup.spin{
                        title = _("界面缩放"), value = UI.getScale(),
                        value_min = UI.scaleMin(), value_max = UI.scaleMax(),
                        value_step = UI.scaleStep(), unit = "%", ok_always_enabled = true,
                        callback = function(spin)
                            local n = UI.setScale(spin.value)
                            UIManager:show(InfoMessage:new{ text = string.format("%d%%", n), timeout = 1.5 })
                            require("utils.font").applyCurrent()
                            desktop:updateView()
                        end,
                    }
                end,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "grid_view", title = _("书架每行数量"),
                subtitle = _("调整书库和 Z站 每行显示的卡片数"),
                status = tostring(grid_max_cols), status_on = true,
                callback = function()
                    Popup.spin{
                        title = _("书架每行数量"), value = UI.getGridMaxCols(),
                        value_min = UI.gridMaxColsMin(), value_max = UI.gridMaxColsMax(),
                        value_step = 1, ok_always_enabled = true,
                        callback = function(spin)
                            UI.setGridMaxCols(spin.value)
                            if desktop.library then desktop.library.state = nil end
                            if desktop.store then desktop.store.state = nil end
                            desktop:updateView()
                        end,
                    }
                end,
            })
        end,
        nightRow(desktop),
    }
    local light = lightRow(desktop)
    if light then rows[#rows + 1] = light end
    local refresh = refreshRow(desktop)
    if refresh then rows[#rows + 1] = refresh end
    local color = colorRow(desktop)
    if color then rows[#rows + 1] = color end
    return rows
end

return Display
