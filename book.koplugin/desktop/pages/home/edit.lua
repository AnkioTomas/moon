--[[--
首页编辑叠层：组件顶栏工具条，其余区域网状遮罩压暗并吞手势。

  +------------------------------+
  | [删] [移] [高] [设]          |   工具条（有 on_settings 才画设置）
  |░░░░░░░░ 组件内容 ░░░░░░░░░░░░|   遮罩：点按 / 长按 / 滑动都不落到组件
  +------------------------------+

@module koplugin.book.desktop.pages.home.edit
--]]

local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Button = require("ui.themes.widgets.button")
local Mask = require("ui.themes.widgets.mask")
local Sheet = require("ui.themes.widgets.sheet")
local Spin = require("ui.themes.widgets.spin")
local _ = require("gettext")
local T = require("ffi/util").template

-- 自定义高度的步进（物理像素）：逐像素点按太慢。
local HEIGHT_STEP = 10

---@class BookHomeEditOverlay
local Edit = {}

--- 在命中范围内吞掉点按 / 长按 / 滑动 / 拖动，不让底层组件收到。
---@param host table
---@param prefix string
local function swallowEvents(host, prefix)
    host.ges_events = {}
    for _i, ges in ipairs({ "Tap", "Hold", "Swipe", "Pan" }) do
        host.ges_events[prefix .. ges] = {
            GestureRange:new{ ges = ges:lower(), range = function() return host.dimen end },
        }
        host["on" .. prefix .. ges] = function() return true end
    end
end

--- 把组件包进编辑模板。有 on_settings 才画设置按钮。
---@param widget table 参与布局或绘制的 Widget
---@param meta { id: string, width: number, height: number, placement: table, range: table }
---@param handlers {
---   on_delete: fun(id: string),
---   on_move: fun(id: string),
---   on_height: fun(id: string, range: table, placement: table),
---   on_settings: fun(id: string)|nil,
--- }
---@return table
function Edit.wrap(widget, meta, handlers)
    local t = Theme.current()
    local w, h = meta.width, meta.height
    local size = Theme.px(t.control.height)
    local row = HorizontalGroup:new{ align = "center" }
    local function add(icon, on_tap)
        if #row > 0 then row[#row + 1] = HorizontalSpan:new{ width = Theme.px(t.space.xs) } end
        row[#row + 1] = Button:new{ icon = icon, variant = "ghost", width = size, height = size, callback = on_tap }
    end
    add("delete", function() handlers.on_delete(meta.id) end)
    add("swap_vert", function() handlers.on_move(meta.id) end)
    add("height", function() handlers.on_height(meta.id, meta.range, meta.placement) end)
    if handlers.on_settings then
        add("settings", function() handlers.on_settings(meta.id) end)
    end
    local bar = Box:new{ style = t.raised, padding = Theme.px(t.space.xs), row }
    local tools = InputContainer:new{ dimen = Geom:new{ w = bar:getSize().w, h = bar:getSize().h }, bar }
    swallowEvents(tools, "HomeEditBar")

    -- 网状遮罩盖住组件内容；工具条叠在上层，不被遮罩糊住。
    local shield = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
        Box:new{
            style = { border = 1, border_color = t.color.ink },
            width = w,
            height = h,
            Mask:new{ dimen = Geom:new{ w = math.max(0, w - 2), h = math.max(0, h - 2) } },
        },
    }
    swallowEvents(shield, "HomeEditShield")

    local overlay = OverlapGroup:new{
        allow_mirroring = false,
        dimen = Geom:new{ w = w, h = h },
        widget,
        shield,
        tools,
    }
    --- 绘制从底到顶；事件从顶到底：先工具条，再遮罩，最后底层组件。
    ---@param event table 父组件转发的事件名称或事件对象
    ---@return boolean
    function overlay:propagateEvent(event)
        for i = #self, 1, -1 do
            if self[i]:handleEvent(event) then return true end
        end
        return false
    end
    return overlay
end

--- 移动菜单。
---@param opts { can_up: boolean, can_down: boolean, can_prev_page: boolean, can_next_page: boolean, on_up: fun(), on_down: fun(), on_prev_page: fun(), on_next_page: fun() }
function Edit.showMoveDialog(opts)
    Sheet:new{
        title = _("移动组件"),
        items = {
            { buttons = {
                { text = _("上移"), enabled = opts.can_up, callback = opts.on_up },
                { text = _("下移"), enabled = opts.can_down, callback = opts.on_down },
            } },
            { buttons = {
                { text = _("移到上一页"), enabled = opts.can_prev_page, callback = opts.on_prev_page },
                { text = _("移到下一页"), enabled = opts.can_next_page ~= false, callback = opts.on_next_page },
            } },
        },
    }:show()
end

--- 高度菜单：默认 / 占满 / 自定义（Spin）。
---@param opts {
---   label: string,
---   range: { height: number, fill?: boolean, limit?: number },
---   current: "default"|"fill"|number,
---   on_apply: fun(height: "default"|"fill"|number),
--- }
function Edit.showHeightDialog(opts)
    local range = opts.range
    local natural = range.height
    local limit = math.max(natural, range.limit or natural)
    local custom = type(opts.current) == "number"
    require("ui.themes.widgets.list"):new{
        title = _("设置高度"), centered = true,
        items = {
            { text = _("默认高度"), checked = opts.current == "default",
                callback = function() opts.on_apply("default") end },
            { text = _("占满剩余"), checked = opts.current == "fill",
                callback = function() opts.on_apply("fill") end },
            { text = custom and T(_("自定义（%1）"), opts.current) or _("自定义高度…"), checked = custom, callback = function()
                Spin:new{
                    title = opts.label or _("高度"),
                    fields = { { value = custom and opts.current or natural, min = 1, max = limit, step = HEIGHT_STEP } },
                    callback = function(value) opts.on_apply(math.floor(value)) end,
                }:show()
            end },
        },
    }:show()
end

--- 添加组件列表：居中分页列表，组件多时翻页而不是溢出屏幕。
---@param candidates { id: string, label: string }[]
---@param on_pick fun(id: string)
function Edit.showAddDialog(candidates, on_pick)
    local items = {}
    for _i, comp in ipairs(candidates) do
        items[#items + 1] = { text = comp.label, value = comp.id }
    end
    require("ui.themes.widgets.list"):new{ title = _("添加组件"), centered = true, items = items, on_select = on_pick }:show()
end

return Edit
