--[[--
设置行：图标 + 标题(+副标题) + 右侧状态/箭头

布局：
  +-----------------------------------------------+
  | [icon]  标题                          状态 ›  |
  |         副标题（可选）                        |
  +-----------------------------------------------+
  kind=nav 默认带 ›；toggle/action 可无箭头。

  SettingRow.build(width, {
    icon = "source",
    title = "...",
    subtitle = "...",
    kind = "nav"|"toggle"|"action",  -- 默认 nav
    status = "开",
    status_on = true,
    chevron = true,   -- 可覆盖 kind 默认
    callback = fn,
  })

@module koplugin.book.ui.components.settingrow
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local Icon = require("ui.components.icon")

local SettingRow = {}

--- 包一层可点击容器。
---@param w number
---@param h number
---@param on_tap fun()|nil
---@return table
local function tappable(w, h, on_tap)
    local tap = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
    }
    tap.ges_events = {
        TapSettingRow = {
            GestureRange:new{
                ges = "tap",
                range = function() return tap:getSize() end,
            },
        },
    }
    tap.onTapSettingRow = function()
        if on_tap then on_tap() end
        return true
    end
    return tap
end

--- 构建设置行（图标 + 标题 + 状态/箭头）。
---@param width number
---@param opts table|nil
---@return table
function SettingRow.build(width, opts)
    opts = opts or {}
    local kind = opts.kind or "nav"
    local show_chevron = opts.chevron
    if show_chevron == nil then
        show_chevron = kind == "nav"
    end

    local icon_sz = UI.iconSz()
    local pad_x = UI.sz(8)
    local pad_y = UI.sz(8)
    local row_h = opts.subtitle and UI.sz(56) or UI.sz(46)
    local icon_col = icon_sz + UI.sz(4)
    local icon_gap = UI.sz(10)
    local chev_w = show_chevron and UI.sz(16) or 0
    local chev_gap = (show_chevron and opts.status) and UI.sz(2) or 0
    local inner_w = math.max(1, width - pad_x * 2)
    -- 状态至少占内容宽 40%，标题侧至少留 UI.sz(40)
    local status_w = 0
    if opts.status then
        local reserved = icon_col + icon_gap + chev_w + chev_gap + UI.sz(40)
        status_w = math.max(UI.sz(48), math.floor(inner_w * 0.40))
        status_w = math.min(status_w, math.max(UI.sz(48), inner_w - reserved))
    end
    local text_w = math.max(UI.sz(40), inner_w - icon_col - icon_gap - status_w - chev_gap - chev_w)

    local title = TextWidget:new{
        text = opts.title,
        face = UI.face("cfont", 15),
        max_width = text_w,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local text_col = VerticalGroup:new{ align = "left", title }
    if opts.subtitle and opts.subtitle ~= "" then
        table.insert(text_col, VerticalSpan:new{ width = UI.sz(3) })
        table.insert(text_col, TextWidget:new{
            text = opts.subtitle,
            face = UI.face("xx_smallinfofont", 11),
            max_width = text_w,
            fgcolor = UI.muted(),
        })
    end

    local right = HorizontalGroup:new{ align = "center" }
    if opts.status then
        table.insert(right, TextWidget:new{
            text = opts.status,
            face = UI.face("cfont", 14),
            max_width = status_w,
            fgcolor = opts.status_on and Blitbuffer.COLOR_BLACK or UI.muted(),
        })
    end
    if show_chevron then
        if opts.status then
            table.insert(right, HorizontalSpan:new{ width = chev_gap })
        end
        table.insert(right, TextWidget:new{
            text = "›",
            face = UI.face("cfont", 18),
            fgcolor = UI.muted(),
        })
    end

    local right_w = status_w + chev_gap + chev_w
    local icon_w = Icon.widget{ name = opts.icon }
    local inner = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = icon_col, h = row_h - pad_y * 2 },
            icon_w or HorizontalSpan:new{ width = 0 },
        },
        HorizontalSpan:new{ width = icon_gap },
        LeftContainer:new{
            dimen = Geom:new{ w = text_w, h = row_h - pad_y * 2 },
            text_col,
        },
        RightContainer:new{
            dimen = Geom:new{ w = right_w, h = row_h - pad_y * 2 },
            right,
        },
    }

    local tap = tappable(width, row_h, opts.callback)
    tap[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        padding_left = pad_x,
        padding_right = pad_x,
        padding_top = pad_y,
        padding_bottom = pad_y,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = width, h = row_h },
        inner,
    }
    return tap
end

return SettingRow
