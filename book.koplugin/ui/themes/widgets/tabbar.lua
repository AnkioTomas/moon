--[[--
主题底栏 Tab：顶部分割线 + 等分格子；选中格用 selected 令牌（底色 / 文字色 / 底部指示条）。

  +-----------------------------------------+
  | ─────────────────────────────────────── |
  |  [icon]    [icon]    [icon]    [icon]   |
  |   首页      书架      书城      设置    |
  |   ━━━                                   |   selected.mark > 0 才画
  +-----------------------------------------+

  Tabbar.widget(theme, { width = w, tabs = { { id = "home", text = "首页", icon = "home" } },
      active = "home", on_tab = function(id) … end })

未选中格：页面底色 + faint 文字；点当前格不回调。

@module koplugin.book.ui.themes.widgets.tabbar
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LineWidget = require("ui/widget/linewidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local Icon = require("ui.themes.widgets.icon")
local Theme = require("ui.themes.init")
local Box = require("ui.themes.widgets.box")
local Tap = require("ui.themes.widgets.tap")

---@class BookThemeTabbar
local Tabbar = {}

---@param t table 主题令牌
---@param opts table width/tabs/active/on_tab/height
---@return table
function Tabbar.widget(t, opts)
    local rule = math.max(1, Theme.px(t.row.divider))
    local cell_h = (opts.height or Theme.px(t.control.height + t.space.lg)) - rule
    local cell_w = math.floor(opts.width / #opts.tabs)
    local sel = t.selected
    local mark = Theme.px(sel.mark)
    local row = HorizontalGroup:new{ align = "top" }
    for _, tab in ipairs(opts.tabs) do
        local active = tab.id == opts.active
        local ink = active and sel.ink or t.color.faint
        local label = Icon.label{
            name = tab.icon,
            text = tab.text,
            direction = "column",
            size = t.control.icon,
            color = Blitbuffer.Color8(ink),
            face = active and "cfont" or "xx_smallinfofont",
            font_size = t.font.caption + (active and 2 or 0),
            max_width = cell_w,
            gap = Theme.px(t.space.xs),
        }
        local cell = VerticalGroup:new{
            align = "center",
            Box:new{
                style = { bg = active and sel.bg or t.color.page },
                width = cell_w,
                height = cell_h - mark,
                label,
            },
        }
        if mark > 0 then
            cell[#cell + 1] = CenterContainer:new{
                dimen = Geom:new{ w = cell_w, h = mark },
                LineWidget:new{
                    background = Blitbuffer.Color8(active and sel.ink or t.color.page),
                    dimen = Geom:new{ w = math.floor(cell_w / 3), h = mark },
                },
            }
        end
        row[#row + 1] = Tap.wrap(cell, (not active and opts.on_tab) and function() opts.on_tab(tab.id) end or nil)
    end
    return VerticalGroup:new{
        align = "left",
        LineWidget:new{ background = Blitbuffer.Color8(t.color.rule), dimen = Geom:new{ w = opts.width, h = rule } },
        row,
    }
end

return Tabbar
