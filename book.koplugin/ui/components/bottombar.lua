--[[--
通用底栏 Tab 渲染（纯构建，不绑 Desktop / 业务 Tab 列表）。

选中态（墨水屏优先对比）：
  图标不 dim、标签加粗加大、底部短粗指示条
未选中：图标 dim、标签浅灰缩小

布局：
  +-----------------------------------------------+
  | ──────────── 通栏分割线 ───────────────────── |
  |  [icon]  [icon]  [icon]  …                    |
  |  文案    文案    文案                         |
  |   ━━━                                    ←选中 |
  +-----------------------------------------------+

调用方提供 tabs：
  { id = "home", text = _("首页"), icon = "home" }

  BottomBar.build(tabs, active_id)

@module koplugin.book.ui.components.bottombar
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LineWidget = require("ui/widget/linewidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local Button = require("ui/widget/button")
local Screen = Device.screen

local UI = require("ui.components.bookui")
local Icon = require("ui.components.icon")

local BottomBar = {}

--- 构建底栏 widget。
---@param tabs table[] { id, text, icon, callback }
---@param active string|nil 当前选中 tab id
---@param parent table|nil 事件归属父控件
---@return table
function BottomBar.build(tabs, active, on_tab, parent)
    tabs = tabs or {}
    local sw = Screen:getWidth()
    local bh = UI.barH()
    local icon_sz = UI.iconSz()
    local n = math.max(1, #tabs)
    local cell_w = math.floor(sw / n)
    local underline_h = UI.sz(3)
    -- 选中指示条：短粗，避免通栏细线「像分割线」
    local indicator_w = math.min(cell_w - UI.sz(20), math.max(UI.sz(28), icon_sz + UI.sz(12)))
    local row = HorizontalGroup:new{ align = "center" }
    for _, tab in ipairs(tabs) do
        local is_active = active == tab.id
        local icon = Icon.widget{
            name = tab.icon,
            dim = not is_active,
        }
        local label = TextWidget:new{
            text = tab.text,
            face = UI.face(is_active and "cfont" or "xx_smallinfofont", is_active and 14 or 11),
            fgcolor = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_6,
        }
        local content_h = math.max(1, bh - underline_h)
        local cell_content = VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = cell_w, h = content_h },
                VerticalGroup:new{
                    align = "center",
                    VerticalSpan:new{ width = UI.sz(4) },
                    icon,
                    VerticalSpan:new{ width = UI.sz(2) },
                    label,
                },
            },
            CenterContainer:new{
                dimen = Geom:new{ w = cell_w, h = underline_h },
                LineWidget:new{
                    background = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
                    dimen = Geom:new{
                        w = is_active and indicator_w or 1,
                        h = underline_h,
                    },
                },
            },
        }
        local cell = cell_content
        if on_tab then
            cell = Button:new{
                width = cell_w,
                height = bh - UI.line(),
                bordersize = 0,
                padding = 0,
                text = tab.text,
                icon = tab.icon,
                text_font_bold = is_active,
                callback = function() on_tab(tab.id) end,
                show_parent = parent,
            }
        end
        table.insert(row, cell)
    end
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = sw, h = bh },
        VerticalGroup:new{
            align = "left",
            LineWidget:new{
                background = UI.rule(),
                dimen = Geom:new{ w = sw, h = UI.line() },
            },
            row,
        },
    }
end

return BottomBar
