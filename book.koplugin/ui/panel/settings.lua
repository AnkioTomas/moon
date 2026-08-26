--[[-- 快捷面板设置项。
@module koplugin.book.ui.panel.settings
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local SettingRow = require("ui.components.settingrow")
local DesktopPanel = require("ui.panel.desktop")
local ReaderPanel = require("ui.panel.reader")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookQuickPanelSettings
---@field enabledCount fun(): number
---@field sections fun(desktop: table): BookQuickPanelSettingSection[]

local QuickPanel = {}

---@class BookQuickPanelSettingSection
---@field title string
---@field rows BookQuickPanelSettingRowFactory[]

---@class BookQuickPanelSettingRowFactory
---@field __call fun(self: BookQuickPanelSettingRowFactory, width: number): table

--- 按动作作用域选择配置后端。
---@param option BookQuickPanelOption
---@return BookQuickPanelDesktop|BookQuickPanelReader
local function panelFor(option)
    if option.scope == "reader" then return ReaderPanel end
    return DesktopPanel
end

--- 弹出单个快捷动作设置对话框，处理启用、上下移动和关闭。
---@param desktop table
---@param option BookQuickPanelOption
---@return void
local function configure(desktop, option)
    local panel = panelFor(option)
    local dialog
    local buttons = {}
    buttons[#buttons + 1] = {{
        text = option.enabled and _("停用") or _("启用"),
        --- 切换动作启用状态后刷新设置页。
        ---@return void
        callback = function()
            panel.setEnabled(option.id, not option.enabled)
            UIManager:close(dialog)
            desktop:rebuild()
        end,
    }}
    if option.enabled then
        buttons[#buttons + 1] = {
            {
                text = _("上移"), enabled = option.position and option.position > 1,
                --- 把动作向前移动一位后刷新设置页。
                ---@return void
                callback = function()
                    panel.move(option.id, -1)
                    UIManager:close(dialog)
                    desktop:rebuild()
                end,
            },
            {
                text = _("下移"), enabled = option.position and option.position < panel.enabledCount(),
                --- 把动作向后移动一位后刷新设置页。
                ---@return void
                callback = function()
                    panel.move(option.id, 1)
                    UIManager:close(dialog)
                    desktop:rebuild()
                end,
            },
        }
    end
    buttons[#buttons + 1] = {{
        --- 关闭动作配置对话框。
        ---@return void
        text = _("关闭"), callback = function() UIManager:close(dialog) end,
    }}
    dialog = ButtonDialog:new{
        title = option.title, title_align = "center", use_info_style = false, buttons = buttons,
    }
    UIManager:show(dialog)
end

--- 把动作选项转成设置行工厂。
---@param desktop table
---@param options BookQuickPanelOption[]
---@return BookQuickPanelSettingRowFactory[]
local function optionRows(desktop, options)
    local rows = {}
    for _idx, option in ipairs(options) do
        local current = option
        --- 设置页把每项配置为按当前宽度构建的行工厂。
        ---@param iw number
        ---@return table
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
                -- 设备不可用的动作不可配置，避免「启用后不可见」的假状态。
                chevron = current.available,
                --- 点击整行打开该动作的配置对话框。
                ---@return void
                callback = current.available and function() configure(desktop, current) end or nil,
            })
        end
    end
    return rows
end

--- 当前启用的可配置快捷动作总数。
---@return number
function QuickPanel.enabledCount()
    return DesktopPanel.enabledCount() + ReaderPanel.enabledCount()
end

--- 按桌面/阅读分组生成快捷面板设置页。
---@param desktop table
---@return BookQuickPanelSettingSection[]
function QuickPanel.sections(desktop)
    return {
        { title = _("桌面"), rows = optionRows(desktop, DesktopPanel.options()) },
        { title = _("阅读"), rows = optionRows(desktop, ReaderPanel.options()) },
    }
end

---@type BookQuickPanelSettings
return QuickPanel
