--[[--
主题标题栏（替代 TitleBar）：左右各一个可选图标按钮，中间标题 + 副标题，底部分割线。

  +-------------------------------------+
  | [<]         标题              [×]   |
  |            副标题                   |
  +-------------------------------------+   row.divider > 0 时画线（divider = false 不画）

  TitleBar.widget({ width = w, title = "…", subtitle = "…",
      left_icon = "arrow_back", left_callback = fn, right_icon = "close", right_callback = fn })

  右侧可再加一个图标（extra_icon / extra_callback，排在 right_icon 左边），左侧补等宽空位，标题仍居中。

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

---@param opts table width/title/subtitle/subtitle_face/left_icon/left_callback/right_icon/right_callback/extra_icon/extra_callback/divider
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
    local sides = opts.extra_icon and 4 or 2
    local mid_w = math.max(1, opts.width - slot * sides)
    local title = VerticalGroup:new{ align = "center", Text.line("title", opts.title or "", { width = mid_w }) }
    if opts.subtitle then
        title[#title + 1] = Text.line("caption", opts.subtitle, { width = mid_w, color = t.color.muted, face = opts.subtitle_face })
    end
    local line = HorizontalGroup:new{ align = "center" }
    local function cell(w, widget) line[#line + 1] = CenterContainer:new{ dimen = Geom:new{ w = w, h = bar_h }, widget } end
    cell(slot, side(opts.left_icon, opts.left_callback))
    if opts.extra_icon then cell(slot, HorizontalSpan:new{ width = slot }) end
    cell(mid_w, title)
    if opts.extra_icon then cell(slot, side(opts.extra_icon, opts.extra_callback)) end
    cell(slot, side(opts.right_icon, opts.right_callback))
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
