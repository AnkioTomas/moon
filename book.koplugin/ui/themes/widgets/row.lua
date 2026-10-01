--[[--
主题列表行：设置页的每一行、弹出列表的每一项共用。

  +-----------------------------------------------+
  | [icon][img] 标题                    状态  [>] |
  |             副标题（可选）                    |
  +-----------------------------------------------+   row.divider > 0 且 divider ~= false 时画线

  Row.widget({
      width = w, icon = "source", title = "…", subtitle = "…",
      image = "https://…", image_w = 32, image_h = 32,   -- 缩略图（逻辑像素），高度夹到行内
      status = "开", status_on = true,   -- status 也可以直接给控件（字体预览等）
      chevron = true,      -- 缺省：有 callback 就画
      selected = false,    -- 选中项取 selected 令牌（反色主题整行反白）
      enabled = true,      -- false 时置灰、不响应
      divider = true,
      callback = fn,
  })

@module koplugin.book.ui.themes.widgets.row
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local Icon = require("ui.themes.widgets.icon")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Image = require("ui.themes.widgets.image")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")

---@class BookThemeRow
local Row = {}

--- 行高：单行取 row.height，有副标题再加一行说明字。
---@param has_subtitle boolean
---@return number 物理像素
function Row.height(has_subtitle)
    local t = Theme.current()
    return Theme.px(t.row.height) + (has_subtitle and Theme.px(t.font.caption + t.space.xs) or 0)
end

---@param opts table 见模块头
---@return table
function Row.widget(opts)
    if opts.subtitle == "" then opts.subtitle = nil end
    local t = Theme.current()
    local enabled = opts.enabled ~= false
    local sel = opts.selected == true
    local ink = not enabled and t.color.disabled or (sel and t.selected.ink or t.color.ink)
    -- 反色选中行上 muted 灰看不清，副文字跟主文字同色。
    local muted = not enabled and t.color.disabled or (sel and t.selected.ink or t.color.muted)
    local chevron = opts.chevron
    if chevron == nil then chevron = opts.callback ~= nil end

    local h = Row.height(opts.subtitle ~= nil)
    local inner = opts.width - Theme.px(t.space.md) * 2
    local icon_sz = Theme.px(t.control.icon)
    local gap = Theme.px(t.space.sm)
    local icon_w = opts.icon and icon_sz + gap or 0
    local image_h = opts.image and math.min(Theme.px(opts.image_h or t.control.icon), h - Theme.px(t.space.xs) * 2)
    local image_w = opts.image and Theme.px(opts.image_w or opts.image_h or t.control.icon)
    local chev_w = chevron and icon_sz or 0
    local status_widget = type(opts.status) == "table" and opts.status or nil
    local status_w = status_widget and status_widget:getSize().w
        or opts.status and math.floor(inner * 0.4) or 0
    local text_w = math.max(1, inner - icon_w - (image_w and image_w + gap or 0) - status_w - chev_w)

    local content = HorizontalGroup:new{ align = "center" }
    if opts.icon then
        content[#content + 1] = LeftContainer:new{
            dimen = Geom:new{ w = icon_w, h = h },
            Icon.widget{ name = opts.icon, size = t.control.icon, color = Blitbuffer.Color8(ink) },
        }
    end
    if opts.image then
        content[#content + 1] = LeftContainer:new{
            dimen = Geom:new{ w = image_w + gap, h = h },
            Image.widget({ src = opts.image, width = image_w, height = image_h }),
        }
    end
    local texts = VerticalGroup:new{
        align = "left",
        Text.line("body", opts.title, { width = text_w, color = ink, bold = sel }),
    }
    if opts.subtitle then
        texts[#texts + 1] = Text.line("caption", opts.subtitle, { width = text_w, color = muted })
    end
    content[#content + 1] = LeftContainer:new{ dimen = Geom:new{ w = text_w, h = h }, texts }
    if opts.status then
        content[#content + 1] = RightContainer:new{
            dimen = Geom:new{ w = status_w, h = h },
            status_widget or Text.line("body", opts.status, { width = status_w, color = opts.status_on and ink or muted }),
        }
    end
    if chevron then
        content[#content + 1] = CenterContainer:new{
            dimen = Geom:new{ w = chev_w, h = h },
            Icon.widget{ name = "chevron_right", size = t.control.icon, color = Blitbuffer.Color8(muted) },
        }
    end

    local group = VerticalGroup:new{
        align = "left",
        Box:new{ style = { bg = sel and t.selected.bg or nil }, width = opts.width, height = h, content },
    }
    local divider = Theme.px(t.row.divider)
    if opts.divider ~= false and divider > 0 then
        group[#group + 1] = LineWidget:new{
            background = Blitbuffer.Color8(t.color.rule),
            dimen = Geom:new{ w = opts.width, h = divider },
        }
    end
    return Tap.wrap(group, enabled and opts.callback or nil)
end

return Row
