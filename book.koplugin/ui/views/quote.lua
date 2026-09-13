--[[--
共享引言块：左侧引号 + 正文，署名靠右。无卡片。

@module koplugin.book.ui.views.quote
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
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

local ATTR_RATIO = 0.36

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
        pad_x = opts.pad_x ~= nil and math.max(0, math.floor(tonumber(opts.pad_x) or 0)) or 0,
        width = math.max(1, math.floor(tonumber(opts.width) or UI.sz(300))),
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

--- 按真实控件量引言行：引号 + 正文 + 右署名。
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
    local mark_w = mark:getSize().w
    local gap_mark = UI.sz(o.gap_mark)
    local attr_text = M.attribution(quote)
    local attr, attr_w, gap_attr = nil, 0, 0
    if attr_text ~= "" then
        gap_attr = UI.sz(o.gap_attr)
        local attr_max = math.max(1, math.floor(inner_w * ATTR_RATIO))
        attr = TextWidget:new{
            text = attr_text,
            face = UI.face("xx_smallinfofont", o.attr_size),
            max_width = attr_max,
            fgcolor = UI.muted(),
        }
        attr_w = attr:getSize().w
    end
    local face = UI.face("cfont", o.body_size)
    local px = (face and face.size) or UI.fontSize(o.body_size)
    local line_px = math.max(1, math.floor((1 + o.line_em) * px + 0.5))
    local body_w = math.max(1, inner_w - mark_w - gap_mark - gap_attr - attr_w)
    local body = TextBoxWidget:new{
        text = quote and quote.text or "",
        face = face,
        width = body_w,
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
    if attr then
        if gap_attr > 0 then
            table.insert(row, HorizontalSpan:new{ width = gap_attr })
        end
        table.insert(row, attr)
    end
    return {
        row = row,
        body = body,
        attr = attr,
        pad_x = o.pad_x,
        width = o.width,
        inner_h = math.max(mark:getSize().h, body:getSize().h, attr and attr:getSize().h or 0),
    }
end

--- 引言实绘高度（与 build 同构）。
---@param opts table|nil
---@return number
function M.contentHeight(opts)
    return assemble(opts, opts and opts.data).inner_h
end

--- 首页内容高度。
---@param opts table|nil
---@return BookHomeHeightSpec
function M.heightRange(opts)
    return { height = M.contentHeight(opts) }
end

--- 构建引号、正文和右署名。
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
        built.row,
    }
end

--- 替换引言数据并原地更新正文、署名。
---@param quote table
---@return nil
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
