--[[--
首页引言块：两行正文 + 右侧作者 / 书名。一言和书摘共用，避免两套排版。

@module koplugin.book.ui.desktop.home.components.quote
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local LINES = 2
local BODY = 15
local LINE_EM = 0.3
local ATTR_W = 108

local M = {}

function M.heightRange()
    return {
        min = UI.sz(56),
        preferred = UI.sz(72),
        max = UI.sz(96),
        grow = 0,
    }
end

---@param quote { text: string, author: string|nil, title: string|nil }
---@param width number
---@param height number
---@param y number|nil
---@return table
function M.build(quote, width, height, y)
    local pad_x = UI.sz(10)
    local inner_w = math.max(1, width - pad_x * 2)
    local mark = TextWidget:new{
        text = "“",
        face = UI.face("cfont", 28),
        fgcolor = UI.dim(),
    }
    local mark_w = mark:getSize().w
    local attr_w = math.min(UI.sz(ATTR_W), math.max(UI.sz(64), math.floor(inner_w * 0.28)))
    local gap = UI.sz(8)
    local body_w = math.max(1, inner_w - mark_w - gap * 2 - attr_w)
    local face = UI.face("cfont", BODY)
    local px = (face and face.size) or UI.sz(BODY)
    local line_px = math.max(1, math.floor((1 + LINE_EM) * px + 0.5))
    local box_h = line_px * LINES
    local body = TextBoxWidget:new{
        text = quote.text or "",
        face = face,
        width = body_w,
        height = box_h,
        line_height = LINE_EM,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        height_overflow_show_ellipsis = true,
    }
    local author = TextWidget:new{
        text = quote.author or "",
        face = UI.face("xx_smallinfofont", 12),
        max_width = attr_w,
        fgcolor = UI.muted(),
    }
    local title = TextWidget:new{
        text = quote.title or "",
        face = UI.face("xx_smallinfofont", 11),
        max_width = attr_w,
        fgcolor = UI.dim(),
    }
    local attr_h = author:getSize().h + UI.sz(2) + title:getSize().h
    local row = HorizontalGroup:new{
        align = "center",
        mark,
        HorizontalSpan:new{ width = gap },
        body,
        HorizontalSpan:new{ width = gap },
        RightContainer:new{
            dimen = Geom:new{ w = attr_w, h = math.max(box_h, attr_h) },
            VerticalGroup:new{
                align = "right",
                author,
                VerticalSpan:new{ width = UI.sz(2) },
                title,
            },
        },
    }
    local inner_h = math.max(mark:getSize().h, box_h, attr_h)
    local pad_y = math.max(0, math.floor((height - inner_h) / 2))
    return {
        widget = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            padding_left = pad_x,
            padding_right = pad_x,
            padding_top = pad_y,
            padding_bottom = pad_y,
            margin = 0,
            dimen = Geom:new{ w = width, h = height },
            LeftContainer:new{
                dimen = Geom:new{ w = inner_w, h = inner_h },
                row,
            },
        },
        height = height,
        body = body,
        author = author,
        title = title,
        region = Geom:new{ x = 0, y = y or 0, w = width, h = height },
    }
end

---@param parts table
---@param quote { text: string, author: string|nil, title: string|nil }
function M.paint(parts, quote)
    if not parts or not parts.body then return end
    parts.body:setText(quote.text or "")
    parts.author:setText(quote.author or "")
    parts.title:setText(quote.title or "")
end

return M
