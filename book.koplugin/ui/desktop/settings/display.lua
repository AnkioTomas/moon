--[[-- 显示设置项。
@module koplugin.book.ui.desktop.settings.display
--]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Popup = require("ui.components.popup")
local SettingRow = require("ui.components.settingrow")
local FontPicker = require("ui.components.fontpicker")
local UI = require("ui.components.bookui")
local PageTurnAnimation = require("patch.page_turn_animation")
local _ = require("gettext")
local T = require("ffi/util").template

local Display = {}

---@param ctx table
---@return table
function Display.rows(ctx)
    local desktop = ctx.desktop
    local font_name, scale, grid_max_cols = ctx.font_name, ctx.scale, ctx.grid_max_cols
    return {
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "text_fields", title = _("字体"),
                status = font_name, status_on = true,
                callback = function()
                    FontPicker.open{ title = _("字体"), on_done = function() desktop:rebuild() end }
                end,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "format_size", title = _("字号"),
                status = string.format("%d%%", scale), status_on = true,
                callback = function()
                    Popup.spin{
                        title = _("字号"), value = UI.getScale(),
                        value_min = UI.scaleMin(), value_max = UI.scaleMax(),
                        value_step = UI.scaleStep(), unit = "%", ok_always_enabled = true,
                        callback = function(spin)
                            local n = UI.setScale(spin.value)
                            UIManager:show(InfoMessage:new{ text = string.format("%d%%", n), timeout = 1.5 })
                            desktop:rebuild()
                        end,
                    }
                end,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "grid_view", title = _("网格最大列数"),
                status = tostring(grid_max_cols), status_on = true,
                callback = function()
                    Popup.spin{
                        title = _("网格最大列数"), value = UI.getGridMaxCols(),
                        value_min = UI.gridMaxColsMin(), value_max = UI.gridMaxColsMax(),
                        value_step = 1, ok_always_enabled = true,
                        callback = function(spin)
                            UI.setGridMaxCols(spin.value)
                            desktop._library_state = nil
                            desktop._store_state = nil
                            desktop:rebuild()
                        end,
                    }
                end,
            })
        end,
        function(iw)
            local enabled = PageTurnAnimation.isEnabled()
            return SettingRow.build(iw, {
                kind = "toggle", icon = "animation", title = _("翻页动画"),
                status = enabled and _("开") or _("关"), status_on = enabled,
                callback = function()
                    local res = PageTurnAnimation.setEnabled(not enabled)
                    if not res.ok then
                        UIManager:show(InfoMessage:new{
                            text = T(_("翻页动画补丁操作失败：%1"), tostring(res.err or "")),
                            timeout = 3,
                        })
                        return
                    end
                    desktop:rebuild()
                    PageTurnAnimation.promptRestart()
                end,
            })
        end,
    }
end

return Display
