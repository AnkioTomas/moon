--[[-- 快捷面板内容体：可选头部 + 动作按钮网格 + 灯光滑杆；支持现场编辑。
@module koplugin.book.ui.panel.widget.body
--]]

require("l10n").apply()

local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local ActionButton = require("ui.panel.widget.button")
local Edit = require("ui.panel.edit_overlay")
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
---@field editing boolean|nil
---@field on_action fun(id: string)|nil
---@field on_level fun(kind: string, fraction: number): boolean|nil
---@field on_enter_edit fun()|nil
---@field on_exit_edit fun()|nil
---@field on_move fun(id: string, delta: number)|nil
---@field on_disable fun(id: string)|nil
---@field on_add fun(id: string)|nil
---@field addable fun(): { id: string, title: string }[]|nil
---@field show_parent table|nil

local Body = InputContainer:extend{
    name = "book_quick_panel_body",
}

--- 初始化间距和按钮高度，并构建首屏内容。
---@param self BookQuickPanelBody
---@return void
function Body:init()
    self.gap = UI.sz(6)
    self.tile_h = UI.sz(64)
    self:updateView()
end

--- 重新计算网格列数并重建完整纵向布局。
---@param self BookQuickPanelBody
---@return void
function Body:updateView()
    local actions = self.actions or {}
    local sliders = self.sliders or {}
    local editing = self.editing == true
    local columns = columnCount(self.width, math.max(1, #actions), self.gap)
    local tile_w = math.floor((self.width - self.gap * (columns - 1)) / columns)
    local handlers = {
        on_move = function(id, delta)
            if self.on_move then self.on_move(id, delta) end
        end,
        on_disable = function(id)
            if self.on_disable then self.on_disable(id) end
        end,
    }

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
        local button = ActionButton:new{
            width = tile_w,
            height = self.tile_h,
            id = action.id,
            title = action.title,
            icon = action.icon,
            active = action.active,
            enabled = action.enabled,
            on_action = self.on_action,
            on_hold = (not editing and self.on_enter_edit) and function()
                self.on_enter_edit()
                return true
            end or nil,
        }
        if editing then
            button = Edit.wrap(button, {
                id = action.id,
                width = tile_w,
                height = self.tile_h,
                index = i,
                count = #actions,
            }, handlers)
        end
        table.insert(row, button)
    end
    if row then table.insert(group, row) end

    if editing then
        local addable = self.addable and self.addable() or {}
        if #addable > 0 then
            table.insert(group, VerticalSpan:new{ width = UI.sz(8) })
            table.insert(group, Edit.addRow(self.width, function()
                Edit.showAddDialog(addable, function(id)
                    if self.on_add then self.on_add(id) end
                end)
            end))
        end
        table.insert(group, VerticalSpan:new{ width = UI.sz(8) })
        table.insert(group, Edit.doneRow(self.width, function()
            if self.on_exit_edit then self.on_exit_edit() end
        end))
    elseif #sliders > 0 then
        table.insert(group, VerticalSpan:new{ width = UI.sz(10) })
        for _, slider in ipairs(sliders) do
            table.insert(group, SliderRow:new{
                width = self.width,
                height = UI.sz(42),
                kind = slider.kind,
                title = slider.title,
                value = slider.value,
                on_level = self.on_level,
                show_parent = self.show_parent,
            })
        end
    end

    self[1] = group
    self.dimen = Geom:new{ w = self.width, h = group:getSize().h }
    self.ges_events = nil
    if not editing and self.on_enter_edit then
        self.ges_events = {
            HoldPanelEdit = {
                GestureRange:new{ ges = "hold", range = function() return self.dimen end },
            },
        }
    end
end

--- 长按进入现场编辑。
---@return boolean
function Body:onHoldPanelEdit()
    if self.editing or not self.on_enter_edit then return false end
    self.on_enter_edit()
    return true
end

---@type BookQuickPanelBody
return Body
