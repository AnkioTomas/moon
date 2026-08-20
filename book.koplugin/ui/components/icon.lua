--[[--
Material Symbols Outlined 字体图标。

布局：
  widget（方盒居中）     label row              label column
  +----+                 +----------+           +----+
  | 🏠 |                 | 🏠 文案  |           | 🏠 |
  +----+                 +----------+           |文案|
                                                +----+

  Icon.widget{ name = "home", size = 24, color = ..., dim = false }
  Icon.label{ name = "home", text = "首页", direction = "row"|"column", ... }

size 是逻辑值，和 UI.face(name, size) 的 size 同一层：
Font:getFace 内部会 Screen:scaleBySize，所以这里只能过 UI.fontSize（乘 ui_scale），
绝不能传 UI.sz() 的结果，否则 DPI 缩放两次，图标会比文字大一圈。
占位方盒用 UI.sz(size)，与外部按 UI.sz(size) 算的布局对齐。

字体：fonts/MaterialSymbolsOutlined-Regular.ttf（Google Material Symbols Outlined）。
字面：Font.fontmap["moon_icon"]（独立于 UI_FACES，换 UI 字不影响图标）

name 直接写 Material Icons 原名（home / settings / chevron_left …）：
字体用 OpenType rlig 把这串 ASCII 合成图标字形，HarfBuzz 默认启用 rlig。
所以强制 use_xtext（HarfBuzz 路径），不受全局 use_xtext 设置影响。
名字写错时会显示这串英文字面，一眼可见。

@module koplugin.book.ui.components.icon
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
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local UI = require("ui.components.bookui")

local Icon = {}

local FACE = "moon_icon"
local FONT_FILE = "MaterialSymbolsOutlined-Regular.ttf"
--- 默认图标逻辑尺寸（对应 UI.iconSz() 的 UI.sz(24)）
local DEFAULT_SIZE = 24

local _ensured = false

---@param face string
---@param filename string
---@return boolean
local function ensureFont(face, filename)
    local path = UI.pluginRoot() .. "fonts/" .. filename
    if lfs.attributes(path, "mode") ~= "file" then
        logger.err("book.icon missing font", path)
        return false
    end
    FontList:getFontList()
    local listed = false
    for _, p in ipairs(FontList.fontlist or {}) do
        if p == path then
            listed = true
            break
        end
    end
    if not listed then
        table.insert(FontList.fontlist, 1, path)
    end
    Font.fontmap[face] = filename
    return true
end

--- 登记图标字体路径，并固定 moon_icon 字面。
---@return boolean
function Icon.ensure()
    if not _ensured then
        -- MoonFont.applyCurrent 只改 UI_FACES 并清 Font.faces，不碰这里
        _ensured = ensureFont(FACE, FONT_FILE)
    end
    return _ensured
end

--- 纯图标 TextWidget（默认包成 UI.sz(size) 方盒）。
---@param opts table|nil
---@return table|nil
function Icon.widget(opts)
    opts = opts or {}
    local name = opts.name or opts.icon
    if type(name) ~= "string" or name == "" then
        return nil
    end
    if not Icon.ensure() then
        return nil
    end
    local size = math.max(1, tonumber(opts.size) or DEFAULT_SIZE)
    local color = opts.color
    if opts.dim then
        color = UI.muted()
    end
    local tw = TextWidget:new{
        text = name,
        face = Font:getFace(FACE, UI.fontSize(size)),
        fgcolor = color or Blitbuffer.COLOR_BLACK,
        use_xtext = true,
    }
    if opts.box == false then
        return tw
    end
    local box = UI.sz(size)
    return CenterContainer:new{
        dimen = Geom:new{ w = box, h = box },
        tw,
    }
end

--- 图标 + 文案（横排或竖排）。
---@param opts table|nil
---@return table
function Icon.label(opts)
    opts = opts or {}
    local size = math.max(1, tonumber(opts.size) or DEFAULT_SIZE)
    local gap = tonumber(opts.gap) or UI.sz(4)
    local color = opts.color
    if opts.dim then
        color = UI.muted()
    end
    color = color or Blitbuffer.COLOR_BLACK
    local icon = Icon.widget{
        name = opts.name or opts.icon,
        size = size,
        color = color,
        box = opts.box,
    }
    local label = TextWidget:new{
        text = opts.text or "",
        face = UI.face(opts.face or "xx_smallinfofont", opts.font_size or 12),
        fgcolor = opts.text_color or color,
        max_width = opts.max_width,
    }
    if opts.direction == "column" then
        local col = VerticalGroup:new{ align = "center" }
        if icon then
            table.insert(col, icon)
            table.insert(col, VerticalSpan:new{ width = gap })
        end
        table.insert(col, label)
        return col
    end
    local row = HorizontalGroup:new{ align = "center" }
    if icon then
        table.insert(row, icon)
        table.insert(row, HorizontalSpan:new{ width = gap })
    end
    table.insert(row, label)
    return row
end

return Icon
