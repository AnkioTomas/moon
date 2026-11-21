--[[--
主题标题栏（替代 TitleBar）：左侧一个可选图标，右侧可放一个或多个图标按钮，中间标题 + 副标题，底部分割线。

  +-------------------------------------+
  | [<]         标题              [×]   |
  |            副标题                   |
  +-------------------------------------+   row.divider > 0 时画线（divider = false 不画）

  TitleBar.widget({ width = w, title = "…", subtitle = "…",
      left_icon = "arrow_back", left_callback = fn, right_icon = "close", right_callback = fn })

  右侧多个按钮用 right_actions = { { icon, callback }, ... }（从左到右）。
  未传 right_actions 时仍可用 extra_icon / extra_callback（排在 right_icon 左边）。
  左侧补等宽空位，标题仍居中。right_actions 与旧字段同时出现时以 right_actions 为准。

@module koplugin.book.ui.themes.widgets.titlebar
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local Theme = require("ui.themes")
local Button = require("ui.themes.widgets.button")
local Text = require("ui.themes.widgets.text")

---@class BookThemeTitleBar
local TitleBar = {}

--- 标题栏占用高度（含分割线），供全屏页扣减内容区。
---@return number 物理像素
function TitleBar.height()
    local t = Theme.current()
    return Theme.px(t.control.height) + Theme.px(t.space.sm) * 2 + Theme.px(t.row.divider)
end

--- 规范化右侧按钮：优先 right_actions，否则 extra_icon + right_icon。
---@param opts table
---@return table[]
function TitleBar.rightActions(opts)
    opts = opts or {}
    if type(opts.right_actions) == "table" and #opts.right_actions > 0 then
        local out = {}
        for _idx, action in ipairs(opts.right_actions) do
            if type(action) == "table" and type(action.icon) == "string" and action.icon ~= "" then
                out[#out + 1] = action
            end
        end
        return out
    end
    local out = {}
    if type(opts.extra_icon) == "string" and opts.extra_icon ~= "" then
        out[#out + 1] = { icon = opts.extra_icon, callback = opts.extra_callback }
    end
    if type(opts.right_icon) == "string" and opts.right_icon ~= "" then
        out[#out + 1] = { icon = opts.right_icon, callback = opts.right_callback }
    end
    return out
end

---@param opts table width/title/subtitle/subtitle_face/left_icon/left_callback/right_icon/right_callback/extra_icon/extra_callback/right_actions/divider
---@return table
function TitleBar.widget(opts)
    local t = Theme.current()
    local slot = Theme.px(t.control.height)
    local bar_h = TitleBar.height() - Theme.px(t.row.divider)
    --- 图标槽位：没有图标时留等宽空位，保持标题居中。
    ---@param icon string|nil
    ---@param callback fun()|nil
    ---@return table
    local function side(icon, callback)
        if not icon then return HorizontalSpan:new{ width = slot } end
        return Button:new{ icon = icon, variant = "ghost", width = slot, height = slot, callback = callback }
    end
    local actions = TitleBar.rightActions(opts)
    local n = #actions
    -- 无右侧按钮时仍留一个空槽，与原先 right_icon 为空时的居中方式一致。
    local sides = n > 0 and (2 * n) or 2
    local mid_w = math.max(1, opts.width - slot * sides)
    local title = VerticalGroup:new{ align = "center", Text.line("title", opts.title or "", { width = mid_w }) }
    if opts.subtitle then
        title[#title + 1] = Text.line("caption", opts.subtitle, { width = mid_w, color = t.color.muted, face = opts.subtitle_face })
    end
    local line = HorizontalGroup:new{ align = "center" }
    local function cell(w, widget) line[#line + 1] = CenterContainer:new{ dimen = Geom:new{ w = w, h = bar_h }, widget } end
    cell(slot, side(opts.left_icon, opts.left_callback))
    if n > 1 then
        for _idx = 1, n - 1 do
            cell(slot, HorizontalSpan:new{ width = slot })
        end
    end
    cell(mid_w, title)
    if n == 0 then
        cell(slot, side(nil, nil))
    else
        for _idx, action in ipairs(actions) do
            cell(slot, side(action.icon, action.callback))
        end
    end
    local bar = VerticalGroup:new{ align = "left", line }
    local divider = Theme.px(t.row.divider)
    if divider > 0 and opts.divider ~= false then
        bar[#bar + 1] = LineWidget:new{
            background = Blitbuffer.Color8(t.color.rule),
            dimen = Geom:new{ w = opts.width, h = divider },
        }
    end
    return bar
end

return TitleBar
