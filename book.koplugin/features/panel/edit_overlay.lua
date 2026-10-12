--[[--
快捷面板编辑叠层：盖在动作按钮上，吞掉点击，提供前移 / 后移 / 停用。

@module koplugin.book.features.panel.edit_overlay
--]]

require("l10n").apply()

local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Box = require("ui.themes.widgets.box")
local Button = require("ui.themes.widgets.button")
local Sheet = require("ui.themes.widgets.sheet")
local Theme = require("ui.themes")
local _ = require("gettext")

---@class BookQuickPanelEditMeta
---@field id string 动作标识
---@field width number 按钮宽度，单位像素
---@field height number 按钮高度，单位像素
---@field index number 在启用列表中的 1-based 位次
---@field count number 当前启用动作总数

---@class BookQuickPanelEditHandlers
---@field on_move fun(id: string, delta: number) 前移 (-1) 或后移 (+1)
---@field on_disable fun(id: string) 从启用列表移除该动作

---@class BookQuickPanelEditAddOption
---@field id string 动作标识
---@field title string 展示标题

---@class BookQuickPanelEditOverlay
---@field wrap fun(widget: table, meta: BookQuickPanelEditMeta, handlers: BookQuickPanelEditHandlers): table
---@field showAddDialog fun(options: BookQuickPanelEditAddOption[], on_pick: fun(id: string)): nil
local Edit = {}

--- 编辑工具按钮（图标 ghost 按钮）。
---@param name string Material 图标名
---@param enabled boolean 为假时灰显且吞掉点按
---@param on_tap fun() 点击回调
---@return table
local function toolButton(name, enabled, on_tap)
    local size = Theme.px(28)
    return Button:new{
        icon = name, variant = "ghost", enabled = enabled,
        width = size, height = size, callback = on_tap,
    }
end

--- 把动作按钮包进编辑叠层（底层按钮 + 透明盾 + 顶栏工具钮）。
---@param widget table 参与布局或绘制的动作按钮 Widget
---@param meta BookQuickPanelEditMeta 尺寸与列表位次
---@param handlers BookQuickPanelEditHandlers 移动与停用回调
---@return table OverlapGroup 叠层根节点
function Edit.wrap(widget, meta, handlers)
    local w, h = meta.width, meta.height
    local can_prev = meta.index > 1
    local can_next = meta.index < meta.count
    local can_disable = meta.count > 1
    local t = Theme.current()
    local tools = Box:new{
        style = { bg = t.color.page },
        padding = Theme.px(2),
        HorizontalGroup:new{
            align = "center",
            toolButton("chevron_left", can_prev, function() handlers.on_move(meta.id, -1) end),
            HorizontalSpan:new{ width = Theme.px(t.space.xs) },
            toolButton("chevron_right", can_next, function() handlers.on_move(meta.id, 1) end),
            HorizontalSpan:new{ width = Theme.px(t.space.xs) },
            toolButton("close", can_disable, function() handlers.on_disable(meta.id) end),
        },
    }
    tools.overlap_align = "top"

    local shield = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
    }
    shield[1] = Box:new{
        style = { border = t.control.border, border_color = t.color.ink },
        width = w,
        height = h,
    }
    shield.ges_events = {
        TapPanelEditShield = {
            GestureRange:new{ ges = "tap", range = function() return shield.dimen end },
        },
        HoldPanelEditShield = {
            GestureRange:new{ ges = "hold", range = function() return shield.dimen end },
        },
    }
    shield.onTapPanelEditShield = function() return true end
    shield.onHoldPanelEditShield = function() return true end

    local overlay = OverlapGroup:new{
        allow_mirroring = false,
        dimen = Geom:new{ w = w, h = h },
        widget,
        shield,
        tools,
    }
    --- 事件从顶到底：先工具钮，再遮罩，避免点击穿透到底层动作。
    ---@param event table KOReader 事件对象
    ---@return boolean 是否已消费
    function overlay:propagateEvent(event)
        for i = #self, 1, -1 do
            if self[i]:handleEvent(event) then return true end
        end
        return false
    end
    return overlay
end

--- 从未启用动作里挑选要添加的项。
---@param options BookQuickPanelEditAddOption[] 可添加的动作选项
---@param on_pick fun(id: string) 选中后的回调
function Edit.showAddDialog(options, on_pick)
    local items = {}
    for _idx, option in ipairs(options) do
        local id = option.id
        items[#items + 1] = { text = option.title, callback = function() on_pick(id) end }
    end
    if #items == 0 then
        items[1] = { text = _("没有可添加的动作"), enabled = false }
    end
    items[#items + 1] = { separator = true }
    items[#items + 1] = { text = _("关闭") }
    Sheet:new{ title = _("添加动作"), items = items }:show()
end

---@type BookQuickPanelEditOverlay
return Edit
