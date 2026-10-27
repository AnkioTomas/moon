--[[--
快捷面板编辑叠层：风格同首页组件编辑。顶栏工具条，其余区域网状遮罩吞手势。

  +------------------------------+
  | [删] [<] [>]                 |
  |░░░░░░░░ 动作按钮 ░░░░░░░░░░░░|
  +------------------------------+

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
local Mask = require("ui.themes.widgets.mask")
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

--- 在命中范围内吞掉点按 / 长按 / 滑动 / 拖动，不让底层动作收到。
--- 对角滑动例外：那是 KOReader 的截图手势，要放行给下层。
---@param host table
---@param prefix string
local function swallowEvents(host, prefix)
    host.ges_events = {}
    for _i, ges in ipairs({ "Tap", "Hold", "Swipe", "Pan" }) do
        host.ges_events[prefix .. ges] = {
            GestureRange:new{ ges = ges:lower(), range = function() return host.dimen end },
        }
        if ges == "Swipe" then
            host["on" .. prefix .. ges] = function(_self, _arg, ev) return not ev or ev.direction ~= "diagonal" end
        else
            host["on" .. prefix .. ges] = function() return true end
        end
    end
end

--- 把动作按钮包进编辑模板。磁贴比工具条窄时缩小按钮，避免叠到邻居上。
---@param widget table 参与布局或绘制的动作按钮 Widget
---@param meta BookQuickPanelEditMeta 尺寸与列表位次
---@param handlers BookQuickPanelEditHandlers 移动与停用回调
---@return table OverlapGroup 叠层根节点
function Edit.wrap(widget, meta, handlers)
    local t = Theme.current()
    local w, h = meta.width, meta.height
    local gap = Theme.px(t.space.xs)
    local pad = Theme.px(t.space.xs)
    local size = Theme.px(t.control.height)
    local buttons = 3
    local bar_w = size * buttons + gap * (buttons - 1) + pad * 2
    if bar_w > w then
        size = math.max(Theme.px(24), math.floor((w - pad * 2 - gap * (buttons - 1)) / buttons))
    end
    local can_prev = meta.index > 1
    local can_next = meta.index < meta.count
    local row = HorizontalGroup:new{ align = "center" }
    local function add(icon, enabled, on_tap)
        if #row > 0 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = Button:new{
            icon = icon, variant = "ghost", enabled = enabled,
            width = size, height = size, callback = on_tap,
        }
    end
    add("delete", meta.count > 1, function() handlers.on_disable(meta.id) end)
    add("chevron_left", can_prev, function() handlers.on_move(meta.id, -1) end)
    add("chevron_right", can_next, function() handlers.on_move(meta.id, 1) end)
    local bar = Box:new{ style = t.raised, padding = pad, row }
    local tools = InputContainer:new{ dimen = Geom:new{ w = bar:getSize().w, h = bar:getSize().h }, bar }
    swallowEvents(tools, "PanelEditBar")

    local shield = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
        Box:new{
            style = { border = 1, border_color = t.color.ink },
            width = w,
            height = h,
            Mask:new{ dimen = Geom:new{ w = math.max(0, w - 2), h = math.max(0, h - 2) } },
        },
    }
    swallowEvents(shield, "PanelEditShield")

    local overlay = OverlapGroup:new{
        allow_mirroring = false,
        dimen = Geom:new{ w = w, h = h },
        widget,
        shield,
        tools,
    }
    --- 事件从顶到底：先工具条，再遮罩，避免点击穿透到底层动作。
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
