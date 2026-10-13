--[[--
主题图标：Material Symbols Outlined 字体图标（同名目录 icon/MaterialSymbolsOutlined-Regular.ttf）。

  widget（方盒居中）     label row              label column
  +----+                 +----------+           +----+
  | 🏠 |                 | 🏠 文案  |           | 🏠 |
  +----+                 +----------+           |文案|
                                                +----+

  Icon.widget{ name = "home", size = 24, color = c }
  Icon.label{ name = "home", text = "首页", direction = "row"|"column",
              size = 24, color = c, face = "cfont", font_size = 14, gap = px, max_width = px,
              trailing = bool }  -- trailing：图标在文案后（下拉箭头）

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
local Theme = require("ui.themes")

---@class BookThemeIcon
local Icon = {}

local FACE = "moon_icon"
local FONT_FILE = "MaterialSymbolsOutlined-Regular.ttf"

local _ensured = false

--- 把图标字体登记进 FontList，并固定 moon_icon 字面（换 UI 字体不影响图标）。
local function ensureFont()
    if _ensured then return end
    local path = Theme.root() .. "ui/themes/widgets/icon/" .. FONT_FILE
    FontList:getFontList()
    local listed = false
    for _idx, p in ipairs(FontList.fontlist) do
        if p == path then listed = true break end
    end
    if not listed then table.insert(FontList.fontlist, 1, path) end
    Font.fontmap[FACE] = FONT_FILE
    _ensured = true
end

--- 图标字面。size 同 Font:getFace（未缩放的逻辑字号）；要和某段文字同高就传它 face 的 orig_size。
--- 调用方自建 TextWidget（text = 图标名，use_xtext = true）时用，便于缓存控件。
---@param size number
---@return table
function Icon.face(size)
    ensureFont()
    return Font:getFace(FACE, size)
end

---@param opts { name: string, size: number, color: table|nil, box: boolean|nil }
---@return table|nil
function Icon.widget(opts)
    opts = opts or {}
    if type(opts.name) ~= "string" or opts.name == "" then return nil end
    local glyph = TextWidget:new{
        text = opts.name,
        face = Icon.face(Theme.fontSize(opts.size)),
        fgcolor = opts.color or Blitbuffer.COLOR_BLACK,
        use_xtext = true,
    }
    if opts.box == false then return glyph end
    local box = Theme.px(opts.size)
    return CenterContainer:new{
        dimen = Geom:new{ w = box, h = box },
        glyph,
    }
end

---@param opts table 见模块头
---@return table 横排 / 竖排组
function Icon.label(opts)
    local color = opts.color or Blitbuffer.COLOR_BLACK
    local column = opts.direction == "column"
    local group = (column and VerticalGroup or HorizontalGroup):new{ align = "center" }
    local icon = Icon.widget{ name = opts.name, size = opts.size, color = color }
    local text = TextWidget:new{
        text = opts.text,
        face = Theme.face(opts.face or "xx_smallinfofont", opts.font_size or 12),
        fgcolor = color,
        max_width = opts.max_width,
    }
    group[1] = opts.trailing and text or icon
    group[2] = (column and VerticalSpan or HorizontalSpan):new{ width = opts.gap or Theme.px(4) }
    group[3] = opts.trailing and icon or text
    return group
end

return Icon
