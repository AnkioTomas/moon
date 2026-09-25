--[[-- 快捷面板设置项。
@module koplugin.book.ui.panel.settings
--]]

local Popup = require("ui.views.popup")
local SettingRow = require("ui.components.settingrow")
local DesktopPanel = require("ui.panel.desktop")
local ReaderPanel = require("ui.panel.reader")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookQuickPanelSettings
---@field desktopEnabledCount fun(): number
---@field readerEnabledCount fun(): number
---@field desktopRows fun(desktop: table): BookQuickPanelSettingRowFactory[]
---@field readerRows fun(desktop: table): BookQuickPanelSettingRowFactory[]

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
local function configure(desktop, option)
    local panel = panelFor(option)
    --- 执行配置变更后刷新设置页。
    ---@param change fun()
    ---@return fun()
    local function apply(change)
        return function()
            change()
            desktop:updateView()
        end
    end
    local items = {{
        text = option.enabled and _("停用") or _("启用"),
        callback = apply(function() panel.setEnabled(option.id, not option.enabled) end),
    }}
    if option.enabled then
        items[#items + 1] = {
            text = _("上移"), enabled = option.position ~= nil and option.position > 1,
            callback = apply(function() panel.move(option.id, -1) end),
        }
        items[#items + 1] = {
            text = _("下移"), enabled = option.position ~= nil and option.position < panel.enabledCount(),
            callback = apply(function() panel.move(option.id, 1) end),
        }
    end
    items[#items + 1] = { text = _("关闭") }
    Popup.sheet{ title = option.title, items = items }
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
                callback = current.available and function() configure(desktop, current) end or nil,
            })
        end
    end
    return rows
end

--- 当前启用的桌面快捷动作数。
---@return number
function QuickPanel.desktopEnabledCount()
    return DesktopPanel.enabledCount()
end

--- 当前启用的阅读快捷动作数。
---@return number
function QuickPanel.readerEnabledCount()
    return ReaderPanel.enabledCount()
end

--- 生成桌面快捷面板设置行。
---@param desktop table
---@return BookQuickPanelSettingRowFactory[]
function QuickPanel.desktopRows(desktop)
    return optionRows(desktop, DesktopPanel.options())
end

--- 生成阅读快捷面板设置行。
---@param desktop table
---@return BookQuickPanelSettingRowFactory[]
function QuickPanel.readerRows(desktop)
    return optionRows(desktop, ReaderPanel.options())
end

--- 已启用动作的图标横条；不实例化面板主体。
---@param scope string "desktop"|"reader"
---@param width number
---@return table
function QuickPanel.preview(scope, width)
    local Overlay = require("ui.desktop.settings.overlay")
    local Icon = require("ui.components.icon")
    local UI = require("ui.components.bookui")
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local options = scope == "reader" and ReaderPanel.options() or DesktopPanel.options()
    local bar_h = UI.sz(48)
    local pad = UI.sz(10)
    local gap = UI.sz(12)
    local row = HorizontalGroup:new{ align = "center" }
    local n = 0
    for _idx, option in ipairs(options) do
        if option.enabled and option.available then
            if n > 0 then table.insert(row, HorizontalSpan:new{ width = gap }) end
            table.insert(row, Icon.widget{ name = option.icon, size = 22 } or Icon.label{
                name = option.icon, text = option.title, size = 18,
            })
            n = n + 1
        end
    end
    if n == 0 then
        return Overlay.previewPlaceholder(width, bar_h, _("无"))
    end
    local inner_w = math.max(1, width - 2)
    local inner_h = math.max(1, bar_h - 2)
    return Overlay.previewBox(width, LeftContainer:new{
        dimen = Geom:new{ w = inner_w, h = inner_h },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = pad },
            row,
        },
    }, bar_h)
end

---@type BookQuickPanelSettings
return QuickPanel
