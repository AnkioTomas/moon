--[[--
首页编辑叠层：组件顶栏 Action，其余区域 MeshMask 压暗并吞点击。

@module koplugin.book.ui.desktop.home.edit_overlay
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local SpinWidget = require("ui/widget/spinwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local UI = require("ui.components.bookui")
local Icon = require("ui.components.icon")
local MeshMask = require("ui.components.meshmask")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookHomeEditOverlay
local Edit = {}

--- 用控件已绘制的 dimen 做命中，避免 getSize() 丢坐标导致点空穿透。
---@param host table
---@param ges string
---@return table
local function dimenRange(host, ges)
    return GestureRange:new{ ges = ges, range = function() return host.dimen end }
end

--- 在命中范围内吞掉手势，不让底层组件收到。
---@param host table
---@param prefix string
---@return table
local function swallowEvents(host, prefix)
    return {
        [prefix .. "Tap"] = { dimenRange(host, "tap") },
        [prefix .. "Hold"] = { dimenRange(host, "hold") },
        [prefix .. "Swipe"] = { dimenRange(host, "swipe") },
        [prefix .. "Pan"] = { dimenRange(host, "pan") },
    }
end

--- 构建编辑工具按钮，并把命中范围内的点击交给操作回调。
---@param name string Material 图标名
---@param on_tap fun() 点击命中区域时执行的回调
---@return table
local function toolButton(name, on_tap)
    local size = UI.sz(36)
    local tap = InputContainer:new{ dimen = Geom:new{ w = size, h = size } }
    tap[1] = CenterContainer:new{
        dimen = Geom:new{ w = size, h = size },
        Icon.widget{ name = name, size = 20 },
    }
    tap.ges_events = {
        TapHomeEdit = { dimenRange(tap, "tap") },
    }
    tap.onTapHomeEdit = function()
        on_tap()
        return true
    end
    return tap
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
    local w = meta.width
    local h = meta.height
    local kids = { align = "center" }
    local function add(name, on_tap)
        if #kids > 0 then kids[#kids + 1] = HorizontalSpan:new{ width = UI.sz(8) } end
        kids[#kids + 1] = toolButton(name, on_tap)
    end
    add("delete", function() handlers.on_delete(meta.id) end)
    add("swap_vert", function() handlers.on_move(meta.id) end)
    add("height", function()
        handlers.on_height(meta.id, meta.range, meta.placement)
    end)
    if handlers.on_settings then
        add("settings", function() handlers.on_settings(meta.id) end)
    end
    local frame = FrameContainer:new{
        bordersize = 1,
        color = Blitbuffer.COLOR_BLACK,
        padding = UI.sz(4),
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new(kids),
    }
    local size = frame:getSize()
    local tools = InputContainer:new{
        dimen = Geom:new{ w = size.w, h = size.h },
    }
    tools[1] = frame
    tools.ges_events = swallowEvents(tools, "HomeEditBar")
    tools.onHomeEditBarTap = function() return true end
    tools.onHomeEditBarHold = function() return true end
    tools.onHomeEditBarSwipe = function() return true end
    tools.onHomeEditBarPan = function() return true end

    local shield = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
    }
    -- 网状遮罩盖住组件内容；Action 工具条叠在上层，不被遮罩糊住。
    shield[1] = FrameContainer:new{
        bordersize = 1,
        padding = 0,
        margin = 0,
        width = w,
        height = h,
        dimen = Geom:new{ w = w, h = h },
        MeshMask.widget{
            width = math.max(0, w - 2),
            height = math.max(0, h - 2),
        },
    }
    shield.ges_events = swallowEvents(shield, "HomeEditShield")
    shield.onHomeEditShieldTap = function() return true end
    shield.onHomeEditShieldHold = function() return true end
    shield.onHomeEditShieldSwipe = function() return true end
    shield.onHomeEditShieldPan = function() return true end

    local overlay = OverlapGroup:new{
        allow_mirroring = false,
        dimen = Geom:new{ w = w, h = h },
        widget,
        shield,
        tools,
    }
    --- 绘制从底到顶；事件从顶到底：先 Action，再遮罩，最后底层组件。
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

--- 「添加组件」行。
---@param width number 目标宽度，单位像素
---@param on_tap fun() 点击命中区域时执行的回调
---@return table
function Edit.addRow(width, on_tap)
    local h = UI.sz(44)
    local tap = InputContainer:new{ dimen = Geom:new{ w = width, h = h } }
    tap[1] = FrameContainer:new{
        bordersize = 1,
        padding = UI.sz(8),
        background = Blitbuffer.COLOR_WHITE,
        width = width,
        height = h,
        dimen = Geom:new{ w = width, h = h },
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = h - UI.sz(16) },
            TextWidget:new{
                text = _("添加组件"),
                face = UI.face("cfont", 14),
            },
        },
    }
    tap.ges_events = {
        TapHomeAdd = {
            GestureRange:new{ ges = "tap", range = function() return tap:getSize() end },
        },
    }
    tap.onTapHomeAdd = function()
        on_tap()
        return true
    end
    return tap
end

--- 移动菜单。
---@param opts { can_up: boolean, can_down: boolean, can_prev_page: boolean, can_next_page: boolean, on_up: fun(), on_down: fun(), on_prev_page: fun(), on_next_page: fun() }
function Edit.showMoveDialog(opts)
    local dialog
    dialog = ButtonDialog:new{
        title = _("移动组件"),
        buttons = {
            {
                {
                    text = _("上移"),
                    enabled = opts.can_up,
                    callback = function()
                        UIManager:close(dialog)
                        opts.on_up()
                    end,
                },
                {
                    text = _("下移"),
                    enabled = opts.can_down,
                    callback = function()
                        UIManager:close(dialog)
                        opts.on_down()
                    end,
                },
            },
            {
                {
                    text = _("移到上一页"),
                    enabled = opts.can_prev_page,
                    callback = function()
                        UIManager:close(dialog)
                        opts.on_prev_page()
                    end,
                },
                {
                    text = _("移到下一页"),
                    enabled = opts.can_next_page ~= false,
                    callback = function()
                        UIManager:close(dialog)
                        opts.on_next_page()
                    end,
                },
            },
            {{
                text = _("关闭"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

--- 高度菜单：默认 / 占满 / 自定义（SpinWidget）。
---@param opts {
---   label: string,
---   range: { height: number, fill?: boolean, limit?: number },
---   current: "default"|"fill"|number,
---   on_apply: fun(height: "default"|"fill"|number),
--- }
function Edit.showHeightDialog(opts)
    local range = opts.range or {}
    local natural = math.max(1, math.floor(tonumber(range.height) or 1))
    local limit = math.max(natural, math.floor(tonumber(range.limit) or natural))
    local dialog
    --- 关闭高度菜单并调用组件高度应用回调。
    ---@param height number|string 目标高度，单位像素
    local function apply(height)
        UIManager:close(dialog)
        opts.on_apply(height)
    end
    local buttons = {
        {{
            text = opts.current == "default" and _("✓ 默认高度") or _("默认高度"),
            callback = function() apply("default") end,
        }},
        {{
            text = opts.current == "fill" and _("✓ 占满剩余") or _("占满剩余"),
            callback = function() apply("fill") end,
        }},
        {{
            text = type(opts.current) == "number"
                and T(_("✓ 自定义（%1）"), opts.current)
                or _("自定义高度…"),
            callback = function()
                UIManager:close(dialog)
                local cur = type(opts.current) == "number" and opts.current or natural
                local spin = SpinWidget:new{
                    title_text = opts.label or _("高度"),
                    info_text = _("拖动或点按调整组件高度"),
                    value = cur,
                    value_min = 1,
                    value_max = limit,
                    value_step = 1,
                    default_value = natural,
                    callback = function(spin_widget)
                        opts.on_apply(math.floor(spin_widget.value))
                    end,
                }
                UIManager:show(spin)
            end,
        }},
        {{
            text = _("关闭"),
            callback = function() UIManager:close(dialog) end,
        }},
    }
    dialog = ButtonDialog:new{
        title = _("设置高度"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- 添加组件列表。
---@param candidates { id: string, label: string }[]
---@param on_pick fun(id: string)
function Edit.showAddDialog(candidates, on_pick)
    local dialog
    local buttons = {}
    for _i, comp in ipairs(candidates) do
        buttons[#buttons + 1] = {{
            text = comp.label,
            callback = function()
                UIManager:close(dialog)
                on_pick(comp.id)
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = _("关闭"),
        callback = function() UIManager:close(dialog) end,
    }}
    dialog = ButtonDialog:new{
        title = _("添加组件"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return Edit
