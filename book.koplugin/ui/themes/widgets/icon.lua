--[[--
主题图标：Material Symbols Outlined 字体图标（fonts/MaterialSymbolsOutlined-Regular.ttf）。

  widget（方盒居中）     label row              label column
  +----+                 +----------+           +----+
  | 🏠 |                 | 🏠 文案  |           | 🏠 |
  +----+                 +----------+           |文案|
                                                +----+

  Icon.widget{ name = "home", size = 24, color = c }
  Icon.label{ name = "home", text = "首页", direction = "row"|"column",
              size = 24, color = c, face = "cfont", font_size = 14, gap = px, max_width = px }

name 写 Material Icons 原名：字体用 OpenType rlig 把 ASCII 合成字形，所以强制 use_xtext。
名字写错时显示英文字面，一眼可见。
size 是逻辑字号，经 Theme.fontSize（Font:getFace 自带 DPI）；占位方盒用 Theme.px(size) 与布局对齐。

@module koplugin.book.ui.themes.widgets.icon
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FontList = require("fontlist")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes.init")

---@class BookThemeIcon
local Icon = {}

local FACE = "moon_icon"
local FONT_FILE = "MaterialSymbolsOutlined-Regular.ttf"

local _ensured = false

--- 把图标字体登记进 FontList，并固定 moon_icon 字面（换 UI 字体不影响图标）。
local function ensureFont()
    if _ensured then return end
    local path = Theme.root() .. "fonts/" .. FONT_FILE
    FontList:getFontList()
    local listed = false
    for _, p in ipairs(FontList.fontlist) do
        if p == path then listed = true break end
    end
    if not listed then table.insert(FontList.fontlist, 1, path) end
    Font.fontmap[FACE] = FONT_FILE
    _ensured = true
end

---@param opts { name: string, size: number, color: table|nil }
---@return table CenterContainer
function Icon.widget(opts)
    ensureFont()
    local box = Theme.px(opts.size)
    return CenterContainer:new{
        dimen = Geom:new{ w = box, h = box },
        TextWidget:new{
            text = opts.name,
            face = Font:getFace(FACE, Theme.fontSize(opts.size)),
            fgcolor = opts.color or Blitbuffer.COLOR_BLACK,
            use_xtext = true,
        },
    }
end

---@param opts table 见模块头
---@return table 横排 / 竖排组
function Icon.label(opts)
    local color = opts.color or Blitbuffer.COLOR_BLACK
    local column = opts.direction == "column"
    local group = (column and VerticalGroup or HorizontalGroup):new{ align = "center" }
    group[1] = Icon.widget{ name = opts.name, size = opts.size, color = color }
    group[2] = (column and VerticalSpan or HorizontalSpan):new{ width = opts.gap or Theme.px(4) }
    group[3] = TextWidget:new{
        text = opts.text,
        face = Theme.face(opts.face or "xx_smallinfofont", opts.font_size or 12),
        fgcolor = color,
        max_width = opts.max_width,
    }
    return group
end

return Icon
