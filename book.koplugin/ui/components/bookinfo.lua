--[[--
书籍展示共用件：字段取值、封面角标、百分比+进度条、紧凑英雄卡。
  home / detail 共用，禁止各页再抄一份 bookPct。

布局：

  progressBadge（叠在封面上）     progressRow
  +----------+                   +--------------------+
  |     [NN%]|                   | NN%  ========····  |
  |  cover   |                   +--------------------+
  |          |
  +----------+

  hero（左封面，右栏等高）
  +------+  +---------------------------+
  |cover |  | 书名                      |
  |      |  | 作者 [/副文案]            |
  |      |  | 简介（吃满中间余量）…     |
  |      |  |                           |
  |      |  | NN%  ========····  ←贴底  |
  +------+  +---------------------------+

@module koplugin.book.ui.components.bookinfo
--]]

local Blitbuffer = require("ffi/blitbuffer")
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
local Surface = require("ui.components.surface")
local _ = require("gettext")

local BookInfo = {}

--- 取书籍 stable_id（文件身份）。
---@param book Book|table|nil
---@return string|nil
function BookInfo.file(book)
    if type(book) ~= "table" then return nil end
    if type(book.stable_id) == "string" then
        return book.stable_id
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
    local badge = Surface.pill(TextWidget:new{
            text = string.format("%.0f%%", pct),
            face = UI.face("xx_smallinfofont", 11),
            fgcolor = Blitbuffer.COLOR_WHITE,
        }, {
            padding = UI.sz(2),
            width = nil,
            height = UI.sz(20),
            background = Blitbuffer.COLOR_BLACK,
            shadow = false,
        })
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
--- opts.src / opts.headers: 直接指定封面（刮削结果没有 source.coverRequest）
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
    local req
    if type(opts.src) == "string" and opts.src ~= "" then
        req = { url = opts.src, headers = opts.headers }
    elseif type(book) == "table" and type(book.cover_url) == "string" and book.cover_url ~= "" then
        req = { url = book.cover_url, headers = book.cover_headers }
    elseif type(book) == "table" and type(book.cover) == "string" and book.cover ~= "" then
        req = { url = book.cover, headers = book.cover_headers }
    elseif source and type(source.coverRequest) == "function"
        and type(book) == "table" and type(book.stable_id) == "string" then
        req = select(1, source:coverRequest(book))
    end
    local cover_pad = UI.sz(2)
    local cover_w = math.max(UI.sz(16), cw - cover_pad * 2)
    local cover_h = math.max(UI.sz(24), ch - cover_pad * 2)
    local image = Image.widget{
        src = req and req.url or nil,
        headers = req and req.headers or nil,
        width = cover_w,
        height = cover_h,
        alpha = false,
        border = false,
        fallback = title,
        show_parent = opts.show_parent,
        on_ready = opts.on_ready,
        sync = opts.sync,
    }
    local cover = Surface.card(image, {
        padding = cover_pad,
        radius = UI.cardRadius(),
        background = UI.surface(),
        clip = true,
        clip_background = UI.surface(),
        shadow = opts.shadow,
    })
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
--- 上：书名/作者[/副文案]/简介（简介吃满中间余量，不写死行数）
--- 下：进度条贴底（opts.show_progress=false 时隐藏，刮削结果用）
--- opts: width, pad, on_tap, show_progress, subtitle, src, headers；返回 widget, height
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
    local show_progress = opts.show_progress ~= false

    local cover = select(1, BookInfo.cover(plugin, source, book, cw, ch, {
        badge = false,
        show_parent = opts.show_parent,
        on_ready = opts.on_ready,
        src = opts.src,
        headers = opts.headers,
        sync = opts.sync,
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
    local subtitle = opts.subtitle

    local progress_h = 0
    local progress
    if show_progress then
        progress, progress_h = BookInfo.progressRow(info_w, pct)
    end
    local gap_head = UI.sz(2)
    local gap_desc = UI.sz(3)
    local gap_foot = show_progress and UI.sz(4) or 0

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
    local top_kids = {
        align = "left",
        title_w,
        VerticalSpan:new{ width = gap_head },
        author_w,
    }
    if type(subtitle) == "string" and subtitle ~= "" then
        local sub_w = TextWidget:new{
            text = subtitle,
            face = UI.face("xx_smallinfofont", 11),
            max_width = info_w,
            fgcolor = UI.dim(),
        }
        table.insert(top_kids, VerticalSpan:new{ width = gap_head })
        table.insert(top_kids, sub_w)
        head_h = head_h + gap_head + sub_w:getSize().h
    end

    local mid_budget = math.max(0, ch - head_h - gap_foot - progress_h)
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

    if opts.on_tap then
        local tap = BookInfo.tappable(info_w, ch, opts.on_tap)
        tap[1] = info
        info = tap
    end

    local pad_v = UI.sz(6)
    local widget = Surface.card(HorizontalGroup:new{
            align = "top",
            cover_box,
            HorizontalSpan:new{ width = gap },
            LeftContainer:new{
                dimen = Geom:new{ w = info_w, h = ch },
                info,
            },
        }, {
        padding = pad,
        padding_top = pad_v,
        padding_bottom = pad_v,
        background = false,
        radius = 0,
        shadow = false,
    })
    return widget, widget:getSize().h
end

return BookInfo
