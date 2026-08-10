--[[--
书库封面网格 + 底部分页条

@module koplugin.book.modules.covergrid
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Cover = require("cover")
local UI = require("bookui")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local M = {
    id = "covergrid",
    title = "封面网格",
}

local function colsForWidth(w)
    if w >= Screen:scaleBySize(900) then return 5 end
    if w >= Screen:scaleBySize(700) then return 4 end
    return 3
end

local function cell(ctx, book, cw, ch, label_h)
    local title = book.bookName or book.filename or "?"
    local path = nil
    if ctx.api and ctx.plugin and book.filename then
        path = Cover.ensure(ctx.api, ctx.plugin, book.filename)
    end
    local cover_w = Cover.widget(path, cw, ch, title)
    local pct = tonumber(book.progressPercent) or 0
    if pct > 0 and pct <= 1 then pct = pct * 100 end
    local sub = pct > 0 and string.format("%.0f%%", pct) or (book.author or "")

    local tap = InputContainer:new{
        dimen = Geom:new{ w = cw, h = ch + label_h },
    }
    tap.ges_events = {
        TapBook = {
            GestureRange:new{
                ges = "tap",
                range = function() return tap.dimen end,
            },
        },
    }
    tap.onTapBook = function()
        if ctx.plugin then ctx.plugin:openBook(book) end
        return true
    end
    tap[1] = VerticalGroup:new{
        align = "center",
        cover_w,
        VerticalSpan:new{ width = UI.sz(4) },
        TextWidget:new{
            text = title,
            face = UI.face("xx_smallinfofont", 15),
            max_width = cw,
            bold = true,
        },
        TextWidget:new{
            text = sub,
            face = UI.face("xx_smallinfofont", 13),
            max_width = cw,
            fgcolor = Blitbuffer.gray(0.45),
        },
    }
    return tap
end

local function buildPager(w, opts)
    local page = tonumber(opts.page) or 1
    local pages = math.max(1, tonumber(opts.pages) or 1)
    local total = tonumber(opts.total) or 0
    local pager_h = UI.sz(52)
    local btn_w = math.floor(w / 3)

    local prev_enabled = page > 1 and opts.on_prev ~= nil
    local next_enabled = page < pages and opts.on_next ~= nil

    local prev = Button:new{
        text = _("‹ 上一页"),
        width = btn_w,
        bordersize = 0,
        radius = 0,
        padding = UI.sz(8),
        text_font_face = "cfont",
        text_font_size = math.floor(16 * UI.getScale() / 100 + 0.5),
        enabled = prev_enabled,
        callback = function()
            if prev_enabled and opts.on_prev then opts.on_prev() end
        end,
    }
    local info = Button:new{
        text = total > 0
            and T(_("第 %1/%2 页 · 共 %3 本"), page, pages, total)
            or T(_("第 %1/%2 页"), page, pages),
        width = btn_w,
        bordersize = 0,
        radius = 0,
        padding = UI.sz(8),
        text_font_face = "xx_smallinfofont",
        text_font_size = math.floor(14 * UI.getScale() / 100 + 0.5),
        enabled = false,
    }
    local nxt = Button:new{
        text = _("下一页 ›"),
        width = btn_w,
        bordersize = 0,
        radius = 0,
        padding = UI.sz(8),
        text_font_face = "cfont",
        text_font_size = math.floor(16 * UI.getScale() / 100 + 0.5),
        enabled = next_enabled,
        callback = function()
            if next_enabled and opts.on_next then opts.on_next() end
        end,
    }

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = pager_h },
        VerticalGroup:new{
            align = "left",
            LineWidget:new{
                background = Blitbuffer.gray(0.75),
                dimen = Geom:new{ w = w, h = Size.line.thin },
            },
            HorizontalGroup:new{
                prev,
                info,
                nxt,
            },
        },
    }, pager_h
end

function M.build(ctx, books, opts)
    opts = opts or {}
    local w = ctx.width
    local h = ctx.height
    local pad = UI.sz(10)
    local gap = UI.sz(10)
    local cols = colsForWidth(w)
    local label_h = UI.sz(48)
    local cw = math.floor((w - pad * 2 - gap * (cols - 1)) / cols)
    local ch = math.floor(cw * 1.45)

    local pager, pager_h = buildPager(w, opts)
    local grid_h = math.max(1, h - pager_h)

    local vg = VerticalGroup:new{ align = "center" }
    table.insert(vg, VerticalSpan:new{ width = UI.sz(8) })

    if opts.header then
        table.insert(vg, TextWidget:new{
            text = opts.header,
            face = UI.face("cfont", 18),
            fgcolor = Blitbuffer.gray(0.35),
        })
        table.insert(vg, VerticalSpan:new{ width = UI.sz(8) })
    end

    if not books or #books == 0 then
        table.insert(vg, CenterContainer:new{
            dimen = Geom:new{ w = w, h = UI.sz(80) },
            TextWidget:new{
                text = opts.empty_text or _("没有书籍"),
                face = UI.face("cfont", 18),
                fgcolor = Blitbuffer.gray(0.5),
            },
        })
    else
        local i = 1
        while i <= #books do
            local row = HorizontalGroup:new{}
            table.insert(row, HorizontalSpan:new{ width = pad })
            for c = 1, cols do
                if i > #books then break end
                table.insert(row, cell(ctx, books[i], cw, ch, label_h))
                if c < cols and i < #books then
                    table.insert(row, HorizontalSpan:new{ width = gap })
                end
                i = i + 1
            end
            table.insert(vg, row)
            table.insert(vg, VerticalSpan:new{ width = gap })
        end
    end

    local grid = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = grid_h },
        vg,
    }
    grid.overlap_offset = { 0, 0 }
    pager.overlap_offset = { 0, grid_h }

    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        FrameContainer:new{
            bordersize = 0,
            padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            VerticalSpan:new{ width = h },
        },
        grid,
        pager,
    }
end

return M
