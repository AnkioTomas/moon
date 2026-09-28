--[[--
主题列表行：设置页的每一行、弹出列表的每一项共用。

  +-----------------------------------------------+
  | [icon]  标题                        状态  [>] |
  |         副标题（可选）                        |
  +-----------------------------------------------+   row.divider > 0 且 divider ~= false 时画线

  Row.widget(theme, {
      width = w, icon = "source", title = "…", subtitle = "…",
      status = "开", status_on = true,
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
local Icon = require("ui.components.icon")
local Theme = require("ui.themes.init")
local Box = require("ui.themes.widgets.box")
local Tap = require("ui.themes.widgets.tap")
local Text = require("ui.themes.widgets.text")

---@class BookThemeRow
local Row = {}

--- 行高：单行取 row.height，有副标题再加一行说明字。
---@param t table 主题令牌
---@param has_subtitle boolean
---@return number 物理像素
function Row.height(t, has_subtitle)
    return Theme.px(t.row.height) + (has_subtitle and Theme.px(t.font.caption + t.space.xs) or 0)
end

---@param t table 主题令牌
---@param opts table 见模块头
---@return table
function Row.widget(t, opts)
    local enabled = opts.enabled ~= false
    local sel = opts.selected == true
    local ink = not enabled and t.color.disabled or (sel and t.selected.ink or t.color.ink)
    -- 反色选中行上 muted 灰看不清，副文字跟主文字同色。
    local muted = not enabled and t.color.disabled or (sel and t.selected.ink or t.color.muted)
    local chevron = opts.chevron
    if chevron == nil then chevron = opts.callback ~= nil end

    local h = Row.height(t, opts.subtitle ~= nil)
    local inner = opts.width - Theme.px(t.space.md) * 2
    local icon_sz = Theme.px(t.control.icon)
    local icon_w = opts.icon and icon_sz + Theme.px(t.space.sm) or 0
    local chev_w = chevron and icon_sz or 0
    local status_w = opts.status and math.floor(inner * 0.4) or 0
    local text_w = math.max(1, inner - icon_w - status_w - chev_w)

    local content = HorizontalGroup:new{ align = "center" }
    if opts.icon then
        content[#content + 1] = LeftContainer:new{
            dimen = Geom:new{ w = icon_w, h = h },
            Icon.widget{ name = opts.icon, size = t.control.icon, color = Blitbuffer.Color8(ink) },
        }
    end
    local texts = VerticalGroup:new{
        align = "left",
        Text.line(t, "body", opts.title, { width = text_w, color = ink, bold = sel }),
    }
    if opts.subtitle then
        texts[#texts + 1] = Text.line(t, "caption", opts.subtitle, { width = text_w, color = muted })
    end
    content[#content + 1] = LeftContainer:new{ dimen = Geom:new{ w = text_w, h = h }, texts }
    if opts.status then
        content[#content + 1] = RightContainer:new{
            dimen = Geom:new{ w = status_w, h = h },
            Text.line(t, "body", opts.status, { width = status_w, color = opts.status_on and ink or muted }),
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
