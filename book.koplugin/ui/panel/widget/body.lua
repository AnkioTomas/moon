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
---@param avail_w number 内容区可用宽度，单位像素
---@param count number 动作数量
---@param gap number 列间距，单位像素
---@return number 列数，夹在 1 与 MAX_COLUMNS 之间
local function columnCount(avail_w, count, gap)
    local min_tile = UI.sz(MIN_TILE_WIDTH)
    local cols = math.floor((avail_w + gap) / (min_tile + gap))
    return math.max(1, math.min(count, cols, MAX_COLUMNS))
end

--- 快捷面板主体：可包含书籍头、动作网格和灯光滑杆。
---@class BookQuickPanelBodyAction
---@field id string 动作标识
---@field title string 展示标题
---@field icon string Material 图标名
---@field active boolean|nil 是否高亮为激活态
---@field enabled boolean|nil 为假时点击被吞掉

---@class BookQuickPanelBody : WidgetContainer
---@field width number 内容区宽度，单位像素
---@field height number|nil 可选固定高度
---@field gap number 网格间距，单位像素
---@field tile_h number 动作按钮高度，单位像素
---@field actions BookQuickPanelBodyAction[] 当前启用的动作列表
---@field sliders BookQuickPanelSlider[] 灯光滑杆；编辑态不展示
---@field header table|nil 可选头部（阅读面板书名行）
---@field editing boolean|nil 为真时进入现场编辑叠层
---@field on_action fun(id: string)|nil 非编辑态点击动作
---@field on_level fun(kind: string, fraction: number): boolean|nil 滑杆回调
---@field on_enter_edit fun()|nil 长按进入编辑
---@field on_exit_edit fun()|nil 「完成」退出编辑
---@field on_move fun(id: string, delta: number)|nil 前移/后移
---@field on_disable fun(id: string)|nil 停用动作
---@field on_add fun(id: string)|nil 启用并追加动作
---@field addable (fun(): BookQuickPanelEditAddOption[])|nil 可添加动作列表工厂
---@field show_parent table|nil 原生菜单宿主，供滑杆脏区使用
---@field dimen table|nil 当前内容绝对尺寸
---@field ges_events table|nil 非编辑态挂长按进编辑
---@field updateView fun(self: BookQuickPanelBody)

local Body = InputContainer:extend{
    name = "book_quick_panel_body",
}

--- 初始化间距和按钮高度，并构建首屏内容。
---@param self BookQuickPanelBody
---@return nil
function Body:init()
    self.gap = UI.sz(6)
    self.tile_h = UI.sz(64)
    self:updateView()
end

--- 重新计算网格列数并重建完整纵向布局。
---@param self BookQuickPanelBody
---@return nil
function Body:updateView()
    local actions = self.actions or {}
    local sliders = self.sliders or {}
    local editing = self.editing == true
    local columns = columnCount(self.width, math.max(1, #actions), self.gap)
    local tile_w = math.floor((self.width - self.gap * (columns - 1)) / columns)
    ---@type BookQuickPanelEditHandlers
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

--- 长按空白区域进入现场编辑（按钮自身的 hold 另走 on_hold）。
---@param self BookQuickPanelBody
---@return boolean 是否已消费
function Body:onHoldPanelEdit()
    if self.editing or not self.on_enter_edit then return false end
    self.on_enter_edit()
    return true
end

---@type BookQuickPanelBody
return Body
