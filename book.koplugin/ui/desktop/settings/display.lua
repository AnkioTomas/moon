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
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookSettingsDisplay
local Display = {}
Display.__index = Display

---@return BookSettingsDisplay
function Display.new()
    return setmetatable({}, Display)
end

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
            subtitle = _("墨水屏全刷间隔；翻页动画开启时会临时改为从不"),
            status = refreshRateLabel(day), status_on = true,
            callback = function()
                local items = {}
                for _, preset in ipairs(REFRESH_PRESETS) do
                    items[#items + 1] = {
                        text = preset.text,
                        value = preset.value,
                        checked = day == preset.value,
                    }
                end
                Popup.list{
                    title = _("屏幕刷新"),
                    current = day,
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
                        pcall(function() require("utils.font").applyCurrent() end)
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
                            pcall(function() require("utils.font").applyCurrent() end)
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
    }
    local refresh = refreshRow(desktop)
    if refresh then rows[#rows + 1] = refresh end
    local color = colorRow(desktop)
    if color then rows[#rows + 1] = color end
    return rows
end

return Display
