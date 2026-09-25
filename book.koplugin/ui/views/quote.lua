--[[--
共享引言块：上方正文（左侧引号），下方署名靠右。无卡片。

@module koplugin.book.ui.views.quote
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UI = require("ui.components.bookui")

local DEFAULTS = {
    lines = 2,
    body_size = 15,
    line_em = 0.4,
    attr_size = 12,
    mark_size = 28,
    gap_mark = 8,
    gap_attr = 8,
}

local View = require("ui.view")
---@class BookQuote : View
---@field body table|nil 可原地更新的引言正文文字控件
---@field attr table|nil 可原地更新的署名文字控件
local M = {}
M.__index = M
setmetatable(M, View)

--- 把引言样式选项与默认值合并。
---@param opts table|nil
---@return table
local function resolve(opts)
    opts = opts or {}
    return {
        lines = math.max(1, math.floor(tonumber(opts.lines) or DEFAULTS.lines)),
        body_size = math.max(1, math.floor(tonumber(opts.body_size) or DEFAULTS.body_size)),
        line_em = tonumber(opts.line_em) or DEFAULTS.line_em,
        attr_size = math.max(1, math.floor(tonumber(opts.attr_size) or DEFAULTS.attr_size)),
        mark_size = math.max(1, math.floor(tonumber(opts.mark_size) or DEFAULTS.mark_size)),
        gap_mark = math.max(0, math.floor(tonumber(opts.gap_mark) or DEFAULTS.gap_mark)),
        gap_attr = math.max(0, math.floor(tonumber(opts.gap_attr) or DEFAULTS.gap_attr)),
        pad_x = math.max(0, math.floor(tonumber(opts.pad_x) or 0)),
        width = math.max(1, math.floor(tonumber(opts.width) or UI.sz(300))),
    }
end

--- 署名一行：优先 source；否则 —— 作者 · 书名。
---@param quote { author: string|nil, title: string|nil, source: string|nil }|nil
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

--- 按真实控件量引言：正文在上，署名在下靠右。
---@param opts table|nil
---@param quote table|nil
---@return table
local function assemble(opts, quote)
    local o = resolve(opts)
    local inner_w = math.max(1, o.width - o.pad_x * 2)
    local mark = TextWidget:new{
        text = "“",
        face = UI.face("cfont", o.mark_size),
        max_width = UI.sz(o.mark_size),
        fgcolor = UI.muted(),
    }
    local gap_mark = UI.sz(o.gap_mark)
    local face = UI.face("cfont", o.body_size)
    local px = (face and face.size) or UI.fontSize(o.body_size)
    local line_px = math.max(1, math.floor((1 + o.line_em) * px + 0.5))
    local body = TextBoxWidget:new{
        text = quote and quote.text or "",
        face = face,
        width = math.max(1, inner_w - mark:getSize().w - gap_mark),
        height = line_px * o.lines,
        line_height = o.line_em,
        fgcolor = Blitbuffer.COLOR_BLACK,
        height_overflow_show_ellipsis = true,
    }
    local row = HorizontalGroup:new{ align = "center", mark }
    if gap_mark > 0 then
        table.insert(row, HorizontalSpan:new{ width = gap_mark })
    end
    table.insert(row, body)
    local stack = VerticalGroup:new{ align = "left", row }
    local inner_h = math.max(mark:getSize().h, body:getSize().h)
    local attr_text = M.attribution(quote)
    local attr = nil
    if attr_text ~= "" then
        local gap_attr = UI.sz(o.gap_attr)
        attr = TextWidget:new{
            text = attr_text,
            face = UI.face("xx_smallinfofont", o.attr_size),
            max_width = inner_w,
            fgcolor = UI.muted(),
        }
        if gap_attr > 0 then
            table.insert(stack, VerticalSpan:new{ width = gap_attr })
            inner_h = inner_h + gap_attr
        end
        local attr_h = attr:getSize().h
        table.insert(stack, RightContainer:new{
            dimen = Geom:new{ w = inner_w, h = attr_h },
            attr,
        })
        inner_h = inner_h + attr_h
    end
    return {
        stack = stack,
        body = body,
        attr = attr,
        pad_x = o.pad_x,
        width = o.width,
        inner_h = inner_h,
    }
end

--- 引言实绘高度（与 build 同构）。无数据时预留一行署名，避免首页槽位溢出。
---@param opts table|nil
---@return number
function M.contentHeight(opts)
    local data = opts and opts.data
    if not data then
        data = { source = "——" }
    end
    local built = assemble(opts, data)
    local height = built.inner_h
    if built.stack.free then built.stack:free() end
    return height
end

--- 首页内容高度。
---@param opts table|nil
---@return BookHomeHeightSpec
function M.heightRange(opts)
    return { height = M.contentHeight(opts) }
end

--- 构建上方正文和右下署名。
---@return table
function M:createWidget()
    local opts = self
    local quote = self.data or {}
    local built = assemble(opts, quote)
    local inner_h = built.inner_h
    local height = math.max(1, math.floor(tonumber(opts.height) or inner_h))
    self.body, self.attr = built.body, built.attr
    self.height = height
    local extra = math.max(0, height - inner_h)
    local pad_top = math.floor(extra / 2)
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        padding_left = built.pad_x,
        padding_right = built.pad_x,
        padding_top = pad_top,
        padding_bottom = extra - pad_top,
        margin = 0,
        built.stack,
    }
end

--- 替换引言数据并原地更新正文、署名。
---@param quote table
function M:updateView(quote)
    self.data = quote
    if not self.body then return end
    self.body:setText(quote and quote.text or "")
    if self.attr then
        self.attr:setText(M.attribution(quote))
    end
    self:dirty("content")
end

return M
