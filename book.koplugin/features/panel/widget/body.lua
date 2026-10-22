--[[-- 快捷面板内容体：可选头部 + 动作按钮网格 + 灯光滑杆；支持现场编辑。
@module koplugin.book.features.panel.widget.body
--]]

require("l10n").apply()

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local ActionButton = require("features.panel.widget.button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Button = require("ui.themes.widgets.button")
local Edit = require("features.panel.edit_overlay")
local SliderRow = require("features.panel.widget.slider")
local Theme = require("ui.themes")
local _ = require("gettext")

local MIN_TILE_WIDTH = 72
local MAX_COLUMNS = 8

--- 根据可用宽度和动作数量决定网格列数。
---@param avail_w number 内容区可用宽度，单位像素
---@param count number 动作数量
---@param gap number 列间距，单位像素
---@return number 列数，夹在 1 与 MAX_COLUMNS 之间
local function columnCount(avail_w, count, gap)
    local min_tile = Theme.px(MIN_TILE_WIDTH)
    local cols = math.floor((avail_w + gap) / (min_tile + gap))
    return math.max(1, math.min(count, cols, MAX_COLUMNS))
end

--- 快捷面板主体：可包含书籍头、动作网格和灯光滑杆。
---@class BookQuickPanelBody : WidgetContainer
---@field width number 内容区宽度，单位像素
---@field height number|nil 可选固定高度
---@field gap number 网格间距，单位像素
---@field tile_h number 动作按钮高度，单位像素
---@field actions BookQuickPanelMenuItem[] 当前启用且可用的动作（可见顺序）
---@field sliders BookQuickPanelSlider[] 灯光滑杆；编辑态不展示
---@field header table|nil 可选头部（阅读面板书名行）
---@field editing boolean|nil 为真时进入现场编辑叠层
---@field on_action fun(id: string)|nil 非编辑态点击动作
---@field on_level fun(kind: string, fraction: number): boolean|nil 滑杆回调
---@field on_exit_edit fun()|nil 「完成」退出编辑
---@field on_move fun(id: string, other_id: string)|nil 与可见的前 / 后邻居互换
---@field on_disable fun(id: string)|nil 停用动作
---@field on_add fun(id: string)|nil 启用并追加动作
---@field addable (fun(): BookQuickPanelEditAddOption[])|nil 可添加动作列表工厂
---@field show_parent table|nil 原生菜单宿主，供滑杆脏区使用
---@field dimen table|nil 当前内容绝对尺寸
---@field ges_events table 必须是表：InputContainer:onGesture 会 pairs(self.ges_events)
---@field updateView fun(self: BookQuickPanelBody)

local Body = InputContainer:extend{
    name = "book_quick_panel_body",
}

--- 初始化间距和按钮高度，并构建首屏内容。
---@param self BookQuickPanelBody
function Body:init()
    self.gap = Theme.px(6)
    -- 容得下 circle 底座（52）+ 间距 + 一行 caption。
    self.tile_h = Theme.px(76)
    self:updateView()
end

--- 重新计算网格列数并重建完整纵向布局。
---@param self BookQuickPanelBody
function Body:updateView()
    local actions = self.actions or {}
    local sliders = self.sliders or {}
    local editing = self.editing == true
    local columns = columnCount(self.width, math.max(1, #actions), self.gap)
    local tile_w = math.floor((self.width - self.gap * (columns - 1)) / columns)
    local position = {}
    for i, action in ipairs(actions) do position[action.id] = i end
    ---@type BookQuickPanelEditHandlers
    local handlers = {
        on_move = function(id, delta)
            self.on_move(id, actions[position[id] + delta].id)
        end,
        on_disable = self.on_disable,
    }

    local group = VerticalGroup:new{ align = "left" }
    if self.header then
        table.insert(group, self.header)
        table.insert(group, VerticalSpan:new{ width = Theme.px(10) })
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
            on_action = self.on_action,
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
        local t = Theme.current()
        local row = HorizontalGroup:new{ align = "center" }
        local addable = self.addable()
        if #addable > 0 then
            row[#row + 1] = Button:new{ icon = "add", text = _("添加"), callback = function()
                Edit.showAddDialog(addable, self.on_add)
            end }
            row[#row + 1] = HorizontalSpan:new{ width = Theme.px(t.space.sm) }
        end
        row[#row + 1] = Button:new{
            icon = "check", text = _("完成"), variant = "primary", callback = self.on_exit_edit,
        }
        table.insert(group, VerticalSpan:new{ width = Theme.px(t.space.sm) })
        table.insert(group, CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = row:getSize().h },
            row,
        })
    elseif #sliders > 0 then
        table.insert(group, VerticalSpan:new{ width = Theme.px(10) })
        for _idx, slider in ipairs(sliders) do
            table.insert(group, SliderRow:new{
                width = self.width,
                height = Theme.px(42),
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
    -- 不能设为 nil：InputContainer:onGesture 会直接 pairs(self.ges_events)。
    self.ges_events = {}
end

---@type BookQuickPanelBody
return Body
