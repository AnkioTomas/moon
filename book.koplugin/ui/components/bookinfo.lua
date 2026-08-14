--[[--
书籍展示共用件：字段取值、封面角标、百分比+进度条、紧凑英雄卡。
  home / detail 共用，禁止各页再抄一份 bookPct。

@module koplugin.book.ui.components.bookinfo
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local GestureRange = require("ui/gesturerange")
local Image = require("ui.components.image")
local UI = require("ui.components.bookui")
local _ = require("gettext")

local BookInfo = {}

--- 取书籍 stable_id（文件身份）。
---@param book Book|table|nil
---@return string|nil
function BookInfo.file(book)
    if type(book) ~= "table" then return nil end
    if type(book.ref) == "table" and type(book.ref.stable_id) == "string" then
        return book.ref.stable_id
    end
    return nil
end

--- 取书名；缺省回退文件 id 或「?」。
---@param book Book|table|nil
---@return string
function BookInfo.title(book)
    return (book and book.title) or BookInfo.file(book) or "?"
end

--- 取作者。
---@param book Book|table|nil
---@return string
function BookInfo.author(book)
    if type(book) ~= "table" then return "" end
    return book.authors or ""
end

--- 取简介。
---@param book Book|BookDetail|table|nil
---@return string
function BookInfo.desc(book)
    if type(book) ~= "table" then return "" end
    return tostring(book.intro or "")
end

--- 取阅读进度百分比（0–100）。
---@param book Book|table|nil
---@return number
function BookInfo.pct(book)
    if type(book) ~= "table" then return 0 end
    local p = tonumber(book.percent) or 0
    if p < 0 then p = 0 end
    if p > 100 then p = 100 end
    return p
end

--- 包一层可点击容器。
---@param w number
---@param h number
---@param on_tap fun()|nil
---@return table
function BookInfo.tappable(w, h, on_tap)
    local tap = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
    }
    tap.ges_events = {
        TapBookInfo = {
            GestureRange:new{
                ges = "tap",
                range = function() return tap:getSize() end,
            },
        },
    }
    tap.onTapBookInfo = function()
        if on_tap then on_tap() end
        return true
    end
    return tap
end

--- 封面右上角进度角标；pct≤0 返回 nil。
---@param cw number
---@param pct number|nil
---@return table|nil
function BookInfo.progressBadge(cw, pct)
    if not pct or pct <= 0 then return nil end
    local badge = FrameContainer:new{
        bordersize = math.max(1, UI.line()),
        color = Blitbuffer.COLOR_WHITE,
        padding = UI.sz(2),
        padding_left = UI.sz(4),
        padding_right = UI.sz(4),
        background = Blitbuffer.COLOR_BLACK,
        TextWidget:new{
            text = string.format("%.0f%%", pct),
            face = UI.face("xx_smallinfofont", 11),
            fgcolor = Blitbuffer.COLOR_WHITE,
        },
    }
    local bz = badge:getSize()
    local inset = UI.sz(3)
    badge.overlap_offset = {
        math.max(0, cw - bz.w - inset),
        inset,
    }
    return badge
end

--- 「NN%」+ 进度条；百分比在左。
---@param width number
---@param pct number|nil
---@return table, number
function BookInfo.progressRow(width, pct)
    pct = tonumber(pct) or 0
    local label = TextWidget:new{
        text = string.format("%.0f%%", pct),
        face = UI.face("xx_smallinfofont", 12),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local label_w = label:getSize().w
    local gap = UI.sz(6)
    local bar_h = UI.sz(7)
    local bar_w = math.max(1, width - label_w - gap)
    local row = HorizontalGroup:new{
        align = "center",
        label,
        HorizontalSpan:new{ width = gap },
        UI.progressBar(bar_w, bar_h, pct),
    }
    return row, math.max(label:getSize().h, bar_h)
end

--- 封面 widget；opts.badge=true 叠进度角标；缺图由 Image 自更新占位。
--- opts.show_parent: 窗口级父（Desktop / Detail）
--- opts.on_ready: 图片就绪回调
---@param plugin table|nil
---@param source table|nil
---@param book table|nil
---@param cw number
---@param ch number
---@param opts table|nil
---@return table, number, number
function BookInfo.cover(plugin, source, book, cw, ch, opts)
    opts = opts or {}
    local title = BookInfo.title(book)
    local pct = BookInfo.pct(book)
    local ref = type(book) == "table" and book.ref or nil
    local req
    if source and type(source.coverRequest) == "function" and type(ref) == "table" then
        req = select(1, source:coverRequest(ref))
    end
    local cover = Image.widget{
        src = req and req.url or nil,
        headers = req and req.headers or nil,
        width = cw,
        height = ch,
        alpha = false,
        fit = "letterbox",
        border = true,
        fallback = title,
        show_parent = opts.show_parent,
        on_ready = opts.on_ready,
    }
    if opts.badge then
        local badge = BookInfo.progressBadge(cw, pct)
        if badge then
            cover = OverlapGroup:new{
                dimen = Geom:new{ w = cw, h = ch },
                show_parent = opts.show_parent,
                cover,
                badge,
            }
        end
    end
    return cover, cw, ch
end

--- 英雄卡：左封面，右栏高度对齐封面。
--- 上：书名/作者/简介（简介吃满中间余量，不写死行数）
--- 下：进度条始终贴底
--- opts: width, pad, on_tap；返回 widget, height
---@param plugin table|nil
---@param source table|nil
---@param book table|nil
---@param opts table|nil
---@return table, number
function BookInfo.hero(plugin, source, book, opts)
    opts = opts or {}
    local w = opts.width or 1
    local pad = opts.pad or UI.sz(10)
    local avail = math.max(1, w - pad * 2)
    local gap = UI.sz(8)
    local cw = math.min(UI.sz(80), math.floor(avail * 0.22))
    local ch = math.floor(cw * 3 / 2)

    local cover = select(1, BookInfo.cover(plugin, source, book, cw, ch, {
        badge = false,
        show_parent = opts.show_parent,
        on_ready = opts.on_ready,
    }))
    local cover_box = cover
    if opts.on_tap then
        cover_box = BookInfo.tappable(cw, ch, opts.on_tap)
        cover_box[1] = cover
    end

    local info_w = math.max(UI.sz(40), avail - cw - gap)
    local title = BookInfo.title(book)
    local author = BookInfo.author(book)
    local desc = BookInfo.desc(book)
    local pct = BookInfo.pct(book)

    local progress, progress_h = BookInfo.progressRow(info_w, pct)
    local gap_head = UI.sz(2)
    local gap_desc = UI.sz(3)
    local gap_foot = UI.sz(4)

    local title_w = TextWidget:new{
        text = title,
        face = UI.face("cfont", 16),
        max_width = info_w,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local author_w = TextWidget:new{
        text = author ~= "" and author or _("未知作者"),
        face = UI.face("xx_smallinfofont", 12),
        max_width = info_w,
        fgcolor = UI.muted(),
    }

    local head_h = title_w:getSize().h + gap_head + author_w:getSize().h
    local mid_budget = math.max(0, ch - head_h - gap_foot - progress_h)

    local top_kids = {
        align = "left",
        title_w,
        VerticalSpan:new{ width = gap_head },
        author_w,
    }
    if desc ~= "" and mid_budget > gap_desc then
        table.insert(top_kids, VerticalSpan:new{ width = gap_desc })
        table.insert(top_kids, TextBoxWidget:new{
            text = desc,
            face = UI.face("xx_smallinfofont", 11),
            width = info_w,
            height = mid_budget - gap_desc,
            alignment = "left",
            fgcolor = UI.muted(),
            height_overflow_show_ellipsis = true,
        })
        head_h = head_h + mid_budget
    end

    local filler = math.max(0, ch - head_h - gap_foot - progress_h)
    local info = VerticalGroup:new{
        align = "left",
        VerticalGroup:new(top_kids),
        VerticalSpan:new{ width = filler },
        VerticalSpan:new{ width = gap_foot },
        progress,
    }

    if opts.on_tap then
        local tap = BookInfo.tappable(info_w, ch, opts.on_tap)
        tap[1] = info
        info = tap
    end

    local pad_v = UI.sz(6)
    local widget = FrameContainer:new{
        bordersize = 0,
        padding = pad,
        padding_top = pad_v,
        padding_bottom = pad_v,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "top",
            cover_box,
            HorizontalSpan:new{ width = gap },
            LeftContainer:new{
                dimen = Geom:new{ w = info_w, h = ch },
                info,
            },
        },
    }
    return widget, widget:getSize().h
end

return BookInfo
