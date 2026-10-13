--[[--
英雄卡：左封面，右栏至少与封面等高。作者行始终在。进度条和简介可关。

  +------+  +---------------------------+
  |cover |  | 书名                      |
  |      |  | 作者 [/副文案]            |
  |      |  | 简介（吃满中间余量）…     |
  |      |  | NN%  ========····  ←贴底  |
  +------+  +---------------------------+

@module koplugin.book.ui.widgets.bookhero
--]]

local Book = require("ui.widgets.book")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Box = require("ui.themes.widgets.box")
local Progress = require("ui.themes.widgets.progress")
local Text = require("ui.themes.widgets.text")
local Theme = require("ui.themes")
local _ = require("gettext")

local Hero = {}

--- 「NN%」+ 进度条；百分比在左。
---@param width number
---@param pct number|nil
---@return table, number
local function progressRow(width, pct)
    pct = tonumber(pct) or 0
    local label = Text.line("caption", string.format("%.0f%%", pct))
    local label_w = label:getSize().w
    local gap = Theme.px(6)
    local bar = Progress:new{ width = math.max(1, width - label_w - gap), percent = pct }
    local row = HorizontalGroup:new{
        align = "center",
        label,
        HorizontalSpan:new{ width = gap },
        bar,
    }
    return row, math.max(label:getSize().h, bar:getSize().h)
end

--- opts: width, pad, cover_width, title_lines, on_tap, on_info_tap, show_progress, show_desc, subtitle, src, headers。
--- show_progress / show_desc 缺省显示。show_desc=false 时全文留给下方简介区。
--- title_lines 缺省 1（单行截断）；on_info_tap 缺省同 on_tap（点封面与右栏同一动作）。
---@param plugin table|nil
---@param source table|nil
---@param book table|nil
---@param opts table|nil
---@return table, number
function Hero.widget(plugin, source, book, opts)
    opts = opts or {}
    local w = opts.width or 1
    local t = Theme.current()
    local pad = opts.pad or Theme.px(10)
    local avail = math.max(1, w - pad * 2)
    -- 封面阴影画在 cw 之外，不让出来就压到右栏文字上。
    local gap = Theme.px(t.space.sm) + Theme.px(t.raised.shadow)
    local cw = math.min(Theme.px(80), math.floor(avail * 0.22))
    if opts.cover_width then
        cw = math.max(1, math.min(
            math.floor(opts.cover_width),
            avail - gap - Theme.px(40)
        ))
    end
    local ch = math.floor(cw * 3 / 2)
    local show_progress = opts.show_progress ~= false
    local show_desc = opts.show_desc ~= false

    local cover = select(1, Book.cover(plugin, source, book, cw, ch, {
        badge = false,
        show_parent = opts.show_parent,
        on_ready = opts.on_ready,
        src = opts.src,
        headers = opts.headers,
    }))
    local cover_box = cover
    if opts.on_tap then
        cover_box = Book.tappable(cw, ch, opts.on_tap)
        cover_box[1] = cover
    end

    local info_w = math.max(Theme.px(40), avail - cw - gap)
    local title = Book.title(book)
    local author = Book.author(book)
    local desc = show_desc and Book.desc(book) or ""
    local pct = Book.pct(book)
    local subtitle = opts.subtitle

    local progress_h = 0
    local progress
    if show_progress then
        progress, progress_h = progressRow(info_w, pct)
    end
    local gap_head = Theme.px(2)
    local gap_desc = Theme.px(3)
    local gap_foot = show_progress and Theme.px(t.space.xs) or 0

    local title_w = (opts.title_lines or 1) > 1
        and Text.box("title", title, info_w, { max_lines = opts.title_lines })
        or Text.line("title", title, { width = info_w })
    local author_w = Text.line("caption", author ~= "" and author or _("未知作者"), {
        width = info_w, color = t.color.muted,
    })

    local head_h = title_w:getSize().h + gap_head + author_w:getSize().h
    local top_kids = {
        align = "left",
        title_w,
        VerticalSpan:new{ width = gap_head },
        author_w,
    }
    if type(subtitle) == "string" and subtitle ~= "" then
        local sub_w = Text.line("caption", subtitle, { width = info_w, color = t.color.faint })
        table.insert(top_kids, VerticalSpan:new{ width = gap_head })
        table.insert(top_kids, sub_w)
        head_h = head_h + gap_head + sub_w:getSize().h
    end
    -- 多行书名可能比封面高：右栏随内容长高，不压缩
    local row_h = math.max(ch, head_h + gap_foot + progress_h)

    local mid_budget = math.max(0, row_h - head_h - gap_foot - progress_h)
    if desc ~= "" and mid_budget > gap_desc then
        table.insert(top_kids, VerticalSpan:new{ width = gap_desc })
        table.insert(top_kids, Text.box("caption", desc, info_w, {
            height = mid_budget - gap_desc,
            color = t.color.muted,
            ellipsis = true,
        }))
        head_h = head_h + mid_budget
    end

    local filler = math.max(0, row_h - head_h - gap_foot - progress_h)
    local info_kids = {
        align = "left",
        VerticalGroup:new(top_kids),
        VerticalSpan:new{ width = filler },
    }
    if show_progress then
        table.insert(info_kids, VerticalSpan:new{ width = gap_foot })
        table.insert(info_kids, progress)
    end
    local info = VerticalGroup:new(info_kids)

    local on_info_tap = opts.on_info_tap or opts.on_tap
    if on_info_tap then
        local tap = Book.tappable(info_w, row_h, on_info_tap)
        tap[1] = info
        info = tap
    end

    local widget = Box:new{
        style = { radius = 0, shadow = 0, border = 0, border_color = 0, shadow_color = 0 },
        padding = pad,
        HorizontalGroup:new{
            align = "top",
            cover_box,
            HorizontalSpan:new{ width = gap },
            LeftContainer:new{
                dimen = Geom:new{ w = info_w, h = row_h },
                info,
            },
        },
    }
    return widget, widget:getSize().h
end

return Hero
