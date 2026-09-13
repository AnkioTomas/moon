--[[--
快捷面板编辑叠层：盖在动作按钮上，吞掉点击，提供前移 / 后移 / 停用。

@module koplugin.book.ui.panel.edit_overlay
--]]

require("l10n").apply()

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
local TextWidget = require("ui/widget/textwidget")
local Widget = require("ui/widget/widget")
local UIManager = require("ui/uimanager")
local UI = require("ui.components.bookui")
local Icon = require("ui.components.icon")
local _ = require("gettext")

---@class BookQuickPanelEditOverlay
local Edit = {}

--- 构建编辑工具按钮。
---@param name string
---@param enabled boolean
---@param on_tap fun()
---@return table
local function toolButton(name, enabled, on_tap)
    local size = UI.sz(28)
    local tap = InputContainer:new{ dimen = Geom:new{ w = size, h = size } }
    tap[1] = CenterContainer:new{
        dimen = Geom:new{ w = size, h = size },
        Icon.widget{ name = name, size = 16, dim = not enabled },
    }
    if enabled then
        tap.ges_events = {
            TapPanelEdit = {
                GestureRange:new{ ges = "tap", range = function() return tap:getSize() end },
            },
        }
        tap.onTapPanelEdit = function()
            on_tap()
            return true
        end
    end
    return tap
end

--- 把动作按钮包进编辑叠层。
---@param widget table
---@param meta { id: string, width: number, height: number, index: number, count: number }
---@param handlers {
---   on_move: fun(id: string, delta: number),
---   on_disable: fun(id: string),
--- }
---@return table
function Edit.wrap(widget, meta, handlers)
    local w, h = meta.width, meta.height
    local can_prev = meta.index > 1
    local can_next = meta.index < meta.count
    local can_disable = meta.count > 1
    local tools = FrameContainer:new{
        bordersize = 0,
        padding = UI.sz(2),
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "center",
            toolButton("chevron_left", can_prev, function() handlers.on_move(meta.id, -1) end),
            HorizontalSpan:new{ width = UI.sz(4) },
            toolButton("chevron_right", can_next, function() handlers.on_move(meta.id, 1) end),
            HorizontalSpan:new{ width = UI.sz(4) },
            toolButton("close", can_disable, function() handlers.on_disable(meta.id) end),
        },
    }
    tools.overlap_align = "top"

    local shield = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
    }
    shield[1] = FrameContainer:new{
        bordersize = 1,
        padding = 0,
        margin = 0,
        width = w,
        height = h,
        dimen = Geom:new{ w = w, h = h },
        Widget:new{ dimen = Geom:new{ w = math.max(0, w - 2), h = math.max(0, h - 2) } },
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
    --- 事件从顶到底：先工具钮，再遮罩。
    ---@param event table
    ---@return boolean
    function overlay:propagateEvent(event)
        for i = #self, 1, -1 do
            if self[i]:handleEvent(event) then return true end
        end
        return false
    end
    return overlay
end

--- 「完成」行。
---@param width number
---@param on_tap fun()
---@return table
function Edit.doneRow(width, on_tap)
    local h = UI.sz(40)
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
                text = _("完成"),
                face = UI.face("cfont", 14),
            },
        },
    }
    tap.ges_events = {
        TapPanelEditDone = {
            GestureRange:new{ ges = "tap", range = function() return tap:getSize() end },
        },
    }
    tap.onTapPanelEditDone = function()
        on_tap()
        return true
    end
    return tap
end

--- 「添加动作」行。
---@param width number
---@param on_tap fun()
---@return table
function Edit.addRow(width, on_tap)
    local h = UI.sz(40)
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
                text = _("添加动作"),
                face = UI.face("cfont", 14),
            },
        },
    }
    tap.ges_events = {
        TapPanelEditAdd = {
            GestureRange:new{ ges = "tap", range = function() return tap:getSize() end },
        },
    }
    tap.onTapPanelEditAdd = function()
        on_tap()
        return true
    end
    return tap
end

--- 从未启用动作里挑选要添加的项。
---@param options { id: string, title: string }[]
---@param on_pick fun(id: string)
---@return nil
function Edit.showAddDialog(options, on_pick)
    local dialog
    local buttons = {}
    for _, option in ipairs(options) do
        local id = option.id
        buttons[#buttons + 1] = {{
            text = option.title,
            callback = function()
                UIManager:close(dialog)
                on_pick(id)
            end,
        }}
    end
    if #buttons == 0 then
        buttons[1] = {{ text = _("没有可添加的动作"), enabled = false }}
    end
    buttons[#buttons + 1] = {{
        text = _("关闭"),
        callback = function() UIManager:close(dialog) end,
    }}
    dialog = ButtonDialog:new{
        title = _("添加动作"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return Edit
