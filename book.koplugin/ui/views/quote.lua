--[[--
共享引言块：大引号、正文、细线、一行署名。

首页一言/书摘与锁屏语句面板共用 View，支持原地更新及独立出图。

@module koplugin.book.ui.views.quote
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local DEFAULTS = {
    lines = 2,
    body_size = 15,
    line_em = 0.35,
    mark_size = 26,
    attr_size = 12,
    gap_mark = 2,
    gap_rule = 6,
    gap_attr = 6,
    pad_pref = 16,
}

local View = require("ui.view")
---@class BookQuote : View
---@field body table|nil 可原地更新的引言正文文字控件
---@field attr table|nil 可原地更新的署名文字控件
local M = {}
M.__index = M
setmetatable(M, View)

--- 把引言样式选项与默认值合并，并规范化字号、间距和行数。
---@param opts table|nil 布局尺寸、样式及行为选项；缺省项使用组件默认值
---@return table
local function resolve(opts)
    opts = opts or {}
    return {
        lines = math.max(1, math.floor(tonumber(opts.lines) or DEFAULTS.lines)),
        body_size = math.max(1, math.floor(tonumber(opts.body_size) or DEFAULTS.body_size)),
        line_em = tonumber(opts.line_em) or DEFAULTS.line_em,
        mark_size = math.max(1, math.floor(tonumber(opts.mark_size) or DEFAULTS.mark_size)),
        attr_size = math.max(1, math.floor(tonumber(opts.attr_size) or DEFAULTS.attr_size)),
        gap_mark = math.max(0, math.floor(tonumber(opts.gap_mark) or DEFAULTS.gap_mark)),
        gap_rule = math.max(0, math.floor(tonumber(opts.gap_rule) or DEFAULTS.gap_rule)),
        gap_attr = math.max(0, math.floor(tonumber(opts.gap_attr) or DEFAULTS.gap_attr)),
        pad_x = opts.pad_x ~= nil and math.max(0, math.floor(tonumber(opts.pad_x) or 0)) or UI.sz(14),
        pad_pref = DEFAULTS.pad_pref,
    }
end

--- 署名一行：优先 source；否则 —— 作者 · 书名。
---@param quote { author: string|nil, title: string|nil, source: string|nil }
---@return string
function M.attribution(quote)
    quote = quote or {}
    if type(quote.source) == "string" and quote.source ~= "" then
        if quote.source:match("^——") then return quote.source end
        return "—— " .. quote.source
    end
    local author = type(quote.author) == "string" and quote.author or ""
    local title = type(quote.title) == "string" and quote.title or ""
    if author ~= "" and title ~= "" then
        return "—— " .. author .. " · " .. title
    end
    if author ~= "" then return "—— " .. author end
    if title ~= "" then return "—— " .. title end
    return ""
end

--- 引言实绘高度（与 build 同构）。
---@param opts table|nil 布局尺寸、样式及行为选项；缺省项使用组件默认值
---@return number
function M.contentHeight(opts)
    local o = resolve(opts)
    local body_px = UI.fontSize(o.body_size)
    local line_px = math.max(1, math.floor((1 + o.line_em) * body_px + 0.5))
    return UI.fontSize(o.mark_size) + UI.sz(o.gap_mark) + line_px * o.lines
        + UI.sz(o.gap_rule) + UI.line() + UI.sz(o.gap_attr) + UI.fontSize(o.attr_size)
end

--- 首页内容高度：实绘 + 默认上下内边距。
---@param opts table|nil 布局尺寸、样式及行为选项；缺省项使用组件默认值
---@return BookHomeHeightSpec
function M.heightRange(opts)
    return { height = M.contentHeight(opts) + UI.sz(resolve(opts).pad_pref) }
end

--- 按指定宽高和样式构建引号、正文、分隔线与署名，保存可更新的文字控件。
---@return table
function M:createWidget()
    local opts = self
    local quote = self.data
    local o = resolve(opts)
    local width = math.max(1, math.floor(tonumber(opts.width) or 1))
    local height = math.max(1, math.floor(tonumber(opts.height) or M.contentHeight(opts)))
    quote = quote or {}

    local inner_w = math.max(1, width - o.pad_x * 2)
    local mark = TextWidget:new{
        text = "“",
        face = UI.face("cfont", o.mark_size),
        bold = true,
        fgcolor = UI.dim(),
    }
    local face = UI.face("cfont", o.body_size)
    local px = (face and face.size) or UI.fontSize(o.body_size)
    local line_px = math.max(1, math.floor((1 + o.line_em) * px + 0.5))
    local box_h = line_px * o.lines
    local body = TextBoxWidget:new{
        text = quote.text or "",
        face = face,
        width = inner_w,
        height = box_h,
        line_height = o.line_em,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        height_overflow_show_ellipsis = true,
    }
    local rule = LineWidget:new{
        dimen = Geom:new{ w = inner_w, h = UI.line() },
        background = UI.dim(),
    }
    local attr = TextWidget:new{
        text = M.attribution(quote),
        face = UI.face("xx_smallinfofont", o.attr_size),
        max_width = inner_w,
        fgcolor = UI.muted(),
    }
    local gap_mark = UI.sz(o.gap_mark)
    local gap_rule = UI.sz(o.gap_rule)
    local gap_attr = UI.sz(o.gap_attr)
    local col = VerticalGroup:new{
        align = "left",
        mark,
        VerticalSpan:new{ width = gap_mark },
        body,
        VerticalSpan:new{ width = gap_rule },
        rule,
        VerticalSpan:new{ width = gap_attr },
        RightContainer:new{
            dimen = Geom:new{ w = inner_w, h = attr:getSize().h },
            attr,
        },
    }
    local inner_h = mark:getSize().h + gap_mark + box_h
        + gap_rule + UI.line() + gap_attr + attr:getSize().h
    local pad_y = math.max(0, math.floor((height - inner_h) / 2))
    self.body, self.attr = body, attr
    self.height = height
    local widget = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            padding_left = o.pad_x,
            padding_right = o.pad_x,
            padding_top = pad_y,
            padding_bottom = pad_y,
            margin = 0,
            dimen = Geom:new{ w = width, h = height },
            LeftContainer:new{
                dimen = Geom:new{ w = inner_w, h = inner_h },
                col,
            },
        }
    return widget
end

--- 替换引言数据并原地更新正文、署名，保留现有根骨架。
---@param quote table 引言正文、作者和出处数据
---@return nil
function M:updateView(quote)
    self.data = quote
    if not self.body then return end
    self.body:setText(quote and quote.text or "")
    self.attr:setText(M.attribution(quote))
    self:dirty("content")
end

return M
