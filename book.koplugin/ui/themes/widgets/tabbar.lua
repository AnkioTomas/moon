--[[--
主题底栏 Tab：顶部分割线 + 等分格子；选中格用 selected 令牌（底色 / 文字色 / 底部指示条）。

  +-----------------------------------------+
  | ─────────────────────────────────────── |
  |  [icon]    [icon]    [icon]    [icon]   |
  |   首页      书架      书城      设置    |
  |   ━━━                                   |   selected.mark > 0 才画
  +-----------------------------------------+

  Tabbar.widget({ width = w, tabs = { { id = "home", text = "首页", icon = "home" } },
      active = "home", on_tab = function(id) … end })

opts.plain：壁纸透底时用，未选中格的图标文字用主文字色而不是 faint（选中格不变）。

未选中格：页面底色 + faint 文字；点当前格不回调，但照样吞掉点按（不漏给下层手势）。
on_tab(id, rect) 的 rect 是被点格子的屏幕矩形，可作弹层锚点。

@module koplugin.book.ui.themes.widgets.tabbar
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LineWidget = require("ui/widget/linewidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Icon = require("ui.themes.widgets.icon")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Tap = require("ui.themes.widgets.tap")

---@class BookThemeTabbar
local Tabbar = {}

--- 缺省底栏高度（含顶部分割线），供全屏页扣减内容区。
---@return number 物理像素
function Tabbar.height()
    local t = Theme.current()
    return Theme.px(t.control.height + t.space.lg)
end

---@param opts table width/tabs/active/on_tab/height
---@return table
function Tabbar.widget(opts)
    local t = Theme.current()
    local rule = math.max(1, Theme.px(t.row.divider))
    local cell_h = (opts.height or Tabbar.height()) - rule
    local cell_w = math.floor(opts.width / #opts.tabs)
    local sel = t.selected
    local plain = opts.plain
    local mark = Theme.px(sel.mark)
    local row = HorizontalGroup:new{ align = "top" }
    for _idx, tab in ipairs(opts.tabs) do
        local active = tab.id == opts.active
        local ink = active and sel.ink or (plain and t.color.ink or t.color.faint)
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
                -- 选中格多带一个 border 键：壁纸只摘「只有 bg」的页底色，选中底色不能被摘掉。
                style = active and { bg = sel.bg, border = 0 } or { bg = t.color.page },
                width = cell_w,
                height = cell_h - mark,
                label,
            },
        }
        if mark > 0 then
            -- 没选中的格留空隙而不是画页面色线：壁纸透底时页面色线会成为一道白条。
            cell[#cell + 1] = active and CenterContainer:new{
                dimen = Geom:new{ w = cell_w, h = mark },
                LineWidget:new{
                    background = Blitbuffer.Color8(sel.ink),
                    dimen = Geom:new{ w = math.floor(cell_w / 3), h = mark },
                },
            } or VerticalSpan:new{ width = mark }
        end
        local tap
        tap = Tap.wrap(cell, opts.on_tab and function()
            if not active then opts.on_tab(tab.id, tap.dimen) end
        end or nil)
        row[#row + 1] = tap
    end
    return VerticalGroup:new{
        align = "left",
        LineWidget:new{ background = Blitbuffer.Color8(t.color.rule), dimen = Geom:new{ w = opts.width, h = rule } },
        row,
    }
end

return Tabbar
