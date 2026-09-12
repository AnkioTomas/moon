--[[-- 显示设置项。
@module koplugin.book.ui.desktop.settings.display
--]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Popup = require("ui.views.popup")
local SettingRow = require("ui.components.settingrow")
local FontPicker = require("ui.components.fontpicker")
local UI = require("ui.components.bookui")
local _ = require("gettext")

---@class BookSettingsDisplay
local Display = {}
Display.__index = Display

---@return BookSettingsDisplay
function Display.new()
    return setmetatable({}, Display)
end


---@param ctx table
---@return table
function Display:rows(ctx)
    local desktop = ctx.desktop
    local font_name, scale, grid_max_cols = ctx.font_name, ctx.scale, ctx.grid_max_cols
    return {
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
                subtitle = _("调整书库和书城每行显示的卡片数"),
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
end

return Display
