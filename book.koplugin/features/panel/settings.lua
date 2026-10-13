--[[-- 快捷面板设置项。
@module koplugin.book.features.panel.settings
--]]

local Sheet = require("ui.themes.widgets.sheet")
local Position = require("desktop.pages.setting.position")
local Row = require("ui.themes.widgets.row")
local DesktopPanel = require("features.panel.desktop")
local ReaderPanel = require("features.panel.reader")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookQuickPanelSettings
---@field enabledCount fun(scope: "desktop"|"reader"): number
---@field rows fun(scope: "desktop"|"reader", desktop: table): BookQuickPanelSettingRowFactory[]
---@field preview fun(scope: "desktop"|"reader", width: number): table

local QuickPanel = {}

---@class BookQuickPanelSettingSection
---@field title string
---@field rows BookQuickPanelSettingRowFactory[]

---@class BookQuickPanelSettingRowFactory
---@field __call fun(self: BookQuickPanelSettingRowFactory, width: number): table

--- 动作作用域 → 配置后端。
---@type table<string, BookQuickPanelDesktop|BookQuickPanelReader>
local PANELS = { desktop = DesktopPanel, reader = ReaderPanel }

--- 弹出单个快捷动作设置对话框，处理启用、上下移动和关闭。
---@param desktop table
---@param option BookQuickPanelOption
local function configure(desktop, option)
    local panel = PANELS[option.scope]
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
        items[#items + 1] = Position.item(option.position, panel.enabledCount(), function(delta)
            panel.move(option.id, delta)
            desktop:updateView()
        end)
    end
    items[#items + 1] = { text = _("关闭") }
    Sheet:new{ title = option.title, items = items }:show()
end

--- 把动作选项转成设置行工厂。
---@param desktop table
---@param options BookQuickPanelOption[]
---@return BookQuickPanelSettingRowFactory[]
local function optionRows(desktop, options)
    local rows = {}
    for _idx, option in ipairs(options) do
        --- 设置页把每项配置为按当前宽度构建的行工厂。
        ---@param iw number
        ---@return table
        rows[#rows + 1] = function(iw)
            local status
            if not option.available then
                status = _("当前设备不可用")
            elseif option.enabled then
                status = T(_("第 %1 位"), option.position)
            else
                status = _("关闭")
            end
            return Row.widget({
                width = iw,
                kind = "nav", icon = option.icon, title = option.title,
                status = status, status_on = option.enabled and option.available,
                -- 设备不可用的动作不可配置，避免「启用后不可见」的假状态。
                chevron = option.available,
                --- 点击整行打开该动作的配置对话框。
                callback = option.available and function() configure(desktop, option) end or nil,
            })
        end
    end
    return rows
end

--- 当前启用的快捷动作数。
---@param scope "desktop"|"reader"
---@return number
function QuickPanel.enabledCount(scope)
    return PANELS[scope].enabledCount()
end

--- 生成快捷面板设置行。
---@param scope "desktop"|"reader"
---@param desktop table
---@return BookQuickPanelSettingRowFactory[]
function QuickPanel.rows(scope, desktop)
    return optionRows(desktop, PANELS[scope].options())
end

--- 已启用动作的图标条，一行放不下就折行；不实例化面板主体。
---@param scope string "desktop"|"reader"
---@param width number
---@return table
function QuickPanel.preview(scope, width)
    local Overlay = require("desktop.pages.setting.overlay")
    local Icon = require("ui.themes.widgets.icon")
    local Theme = require("ui.themes")
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local options = PANELS[scope].options()
    local t = Theme.current()
    local bar_h = Theme.px(t.row.height)
    local pad = Theme.px(10)
    local gap = Theme.px(t.space.md)
    local inner_w = math.max(1, width - 2)
    local avail = inner_w - pad * 2
    local rows = VerticalGroup:new{ align = "left" }
    local row, used
    for _idx, option in ipairs(options) do
        if option.enabled and option.available then
            local icon = Icon.widget{ name = option.icon, size = 22 } or Icon.label{
                name = option.icon, text = option.title, size = 18,
            }
            local w = icon:getSize().w
            if row and used + gap + w > avail then
                rows[#rows + 1] = row
                rows[#rows + 1] = VerticalSpan:new{ width = gap }
                row = nil
            end
            if row then
                row[#row + 1] = HorizontalSpan:new{ width = gap }
                used = used + gap + w
            else
                row, used = HorizontalGroup:new{ align = "center" }, w
            end
            row[#row + 1] = icon
        end
    end
    if not row then
        return Overlay.previewPlaceholder(width, bar_h, _("无"))
    end
    rows[#rows + 1] = row
    local inner_h = math.max(bar_h - 2, rows:getSize().h + gap * 2)
    return Overlay.previewBox(width, LeftContainer:new{
        dimen = Geom:new{ w = inner_w, h = inner_h },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = pad },
            rows,
        },
    }, inner_h + 2)
end

---@type BookQuickPanelSettings
return QuickPanel
