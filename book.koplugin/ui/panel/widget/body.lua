--[[-- 快捷面板内容体：可选头部 + 动作按钮网格 + 灯光滑杆。
@module koplugin.book.ui.panel.widget.body
--]]

require("l10n").apply()

local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local ActionButton = require("ui.panel.widget.button")
local SliderRow = require("ui.panel.widget.slider")
local UI = require("ui.components.bookui")

local MIN_TILE_WIDTH = 72
local MAX_COLUMNS = 8

--- 根据可用宽度和动作数量决定网格列数。
---@param avail_w number
---@param count number
---@param gap number
---@return number
local function columnCount(avail_w, count, gap)
    local min_tile = UI.sz(MIN_TILE_WIDTH)
    local cols = math.floor((avail_w + gap) / (min_tile + gap))
    return math.max(1, math.min(count, cols, MAX_COLUMNS))
end

--- 快捷面板主体：可包含书籍头、动作网格和灯光滑杆。
---@class BookQuickPanelBody : WidgetContainer
---@field width number
---@field height number
---@field gap number
---@field tile_h number
---@field actions table[]
---@field sliders BookQuickPanelSlider[]
---@field header table|nil
---@field on_action fun(id: string)|nil
---@field on_level fun(kind: string, fraction: number): boolean|nil

local Body = InputContainer:extend{
    name = "book_quick_panel_body",
}

--- 初始化间距和按钮高度，并构建首屏内容。
---@param self BookQuickPanelBody
---@return void
function Body:init()
    self.gap = UI.sz(6)
    self.tile_h = UI.sz(64)
    self:rebuild()
end

--- 重新计算网格列数并重建完整纵向布局。
---@param self BookQuickPanelBody
---@return void
function Body:rebuild()
    local actions = self.actions or {}
    local sliders = self.sliders or {}
    local columns = columnCount(self.width, #actions, self.gap)
    local tile_w = math.floor((self.width - self.gap * (columns - 1)) / columns)

    local group = VerticalGroup:new{ align = "left" }
    if self.header then
        table.insert(group, self.header)
        table.insert(group, VerticalSpan:new{ width = UI.sz(10) })
    end

    local row
    for i, action in ipairs(actions) do
        if (i - 1) % columns == 0 then
            if row then
                table.insert(group, row)
                table.insert(group, VerticalSpan:new{ width = self.gap })
            end
            row = HorizontalGroup:new{ align = "center" }
        else
            table.insert(row, HorizontalSpan:new{ width = self.gap })
        end
        table.insert(row, ActionButton:new{
            width = tile_w,
            height = self.tile_h,
            id = action.id,
            title = action.title,
            icon = action.icon,
            active = action.active,
            enabled = action.enabled,
            on_action = self.on_action,
        })
    end
    if row then table.insert(group, row) end

    if #sliders > 0 then table.insert(group, VerticalSpan:new{ width = UI.sz(10) }) end
    for _, slider in ipairs(sliders) do
        table.insert(group, SliderRow:new{
            width = self.width,
            height = UI.sz(42),
            kind = slider.kind,
            title = slider.title,
            value = slider.value,
            on_level = self.on_level,
        })
    end

    self[1] = group
end

---@type BookQuickPanelBody
return Body
