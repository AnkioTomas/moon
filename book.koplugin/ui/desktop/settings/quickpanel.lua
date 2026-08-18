--[[-- 快捷面板设置项。
@module koplugin.book.ui.desktop.settings.quickpanel
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local Popup = require("ui.components.popup")
local SettingRow = require("ui.components.settingrow")
local DesktopPanel = require("ui.desktop.panel")
local _ = require("gettext")
local T = require("ffi/util").template

local QuickPanel = {}

local function pickIcon(desktop, option)
    local items = {}
    for _idx, icon in ipairs(DesktopPanel.iconChoices()) do
        items[#items + 1] = { text = icon, icon = icon, value = icon }
    end
    Popup.list{
        title = _("选择图标"),
        items = items,
        current = option.icon,
        choice_icons = true,
        centered = true,
        on_select = function(icon)
            if icon then
                DesktopPanel.setIcon(option.id, icon)
                desktop:rebuild()
            end
        end,
    }
end

local function configure(desktop, option)
    local dialog
    local buttons = {{
        text = option.enabled and _("停用") or _("启用"),
        callback = function()
            DesktopPanel.setEnabled(option.id, not option.enabled)
            UIManager:close(dialog)
            desktop:rebuild()
        end,
    }}
    if option.enabled then
        buttons[#buttons + 1] = {
            {
                text = _("上移"), enabled = option.position and option.position > 1,
                callback = function()
                    DesktopPanel.move(option.id, -1)
                    UIManager:close(dialog)
                    desktop:rebuild()
                end,
            },
            {
                text = _("下移"), enabled = option.position and option.position < DesktopPanel.enabledCount(),
                callback = function()
                    DesktopPanel.move(option.id, 1)
                    UIManager:close(dialog)
                    desktop:rebuild()
                end,
            },
        }
    end
    buttons[#buttons + 1] = {{
        text = _("选择图标"),
        callback = function()
            UIManager:close(dialog)
            pickIcon(desktop, option)
        end,
    }}
    buttons[#buttons + 1] = {{
        text = _("关闭"), callback = function() UIManager:close(dialog) end,
    }}
    dialog = ButtonDialog:new{
        title = option.title, title_align = "center", use_info_style = false, buttons = buttons,
    }
    UIManager:show(dialog)
end

---@param desktop table
---@return table
function QuickPanel.rows(desktop)
    local rows = {}
    for _idx, option in ipairs(DesktopPanel.options()) do
        local current = option
        rows[#rows + 1] = function(iw)
            local status
            if not current.available then
                status = _("当前设备不可用")
            elseif current.enabled then
                status = T(_("第 %1 位"), current.position)
            else
                status = _("关闭")
            end
            return SettingRow.build(iw, {
                kind = "nav", icon = current.icon, title = current.title,
                status = status, status_on = current.enabled and current.available,
                chevron = true,
                callback = function() configure(desktop, current) end,
            })
        end
    end
    return rows
end

return QuickPanel
