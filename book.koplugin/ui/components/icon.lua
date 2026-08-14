--[[--
Material Icons Outlined 字体图标。

  Icon.widget{ name = "home", size = UI.iconSz(), color = ..., dim = false }
  Icon.label{ name = "home", text = "首页", direction = "row"|"column", ... }

字体：fonts/MaterialIconsOutlined-Regular.otf
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
local FONT_FILE = "MaterialIconsOutlined-Regular.otf"

local _ensured = false

--- 登记图标字体路径，并固定 moon_icon 字面。
---@return boolean
function Icon.ensure()
    local path = UI.pluginRoot() .. "fonts/" .. FONT_FILE
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
    -- MoonFont.applyCurrent 只改 UI_FACES 并清 Font.faces，不碰这里
    Font.fontmap[FACE] = FONT_FILE
    _ensured = true
    return true
end

--- 纯图标 TextWidget（默认包成 size×size 方盒）。
---@param opts table|nil
---@return table|nil
function Icon.widget(opts)
    opts = opts or {}
    local name = opts.name or opts.icon
    if type(name) ~= "string" or name == "" then
        return nil
    end
    if not _ensured then
        Icon.ensure()
    end
    local size = math.max(1, tonumber(opts.size) or UI.iconSz())
    local color = opts.color
    if opts.dim then
        color = UI.muted()
    end
    -- 图标尺寸已是 UI.sz() 结果，不能再过 UI.fontSize 乘一次 ui_scale
    local tw = TextWidget:new{
        text = name,
        face = Font:getFace(FACE, size),
        fgcolor = color or Blitbuffer.COLOR_BLACK,
        use_xtext = true,
    }
    if opts.box == false then
        return tw
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = size, h = size },
        tw,
    }
end

--- 图标 + 文案（横排或竖排）。
---@param opts table|nil
---@return table
function Icon.label(opts)
    opts = opts or {}
    local size = math.max(1, tonumber(opts.size) or UI.iconSz())
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
