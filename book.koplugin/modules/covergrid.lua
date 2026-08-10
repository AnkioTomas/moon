--[[--
书库封面网格模块

@module koplugin.book.modules.covergrid
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Cover = require("cover")
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
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        TextWidget:new{
            text = title,
            face = Font:getFace("xx_smallinfofont", 13),
            max_width = cw,
            bold = true,
        },
        TextWidget:new{
            text = sub,
            face = Font:getFace("xx_smallinfofont", 11),
            max_width = cw,
            fgcolor = Blitbuffer.gray(0.45),
        },
    }
    return tap
end

--- books: array, page/total for footer
function M.build(ctx, books, opts)
    opts = opts or {}
    local w = ctx.width
    local h = ctx.height
    local pad = Screen:scaleBySize(10)
    local gap = Screen:scaleBySize(10)
    local cols = colsForWidth(w)
    local label_h = Screen:scaleBySize(40)
    local cw = math.floor((w - pad * 2 - gap * (cols - 1)) / cols)
    local ch = math.floor(cw * 1.45)

    local vg = VerticalGroup:new{ align = "center" }
    table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(8) })

    if opts.header then
        table.insert(vg, TextWidget:new{
            text = opts.header,
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.gray(0.35),
        })
        table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(8) })
    end

    if not books or #books == 0 then
        table.insert(vg, CenterContainer:new{
            dimen = Geom:new{ w = w, h = Screen:scaleBySize(80) },
            TextWidget:new{
                text = opts.empty_text or _("没有书籍"),
                face = Font:getFace("cfont", 16),
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

    if opts.page and opts.pages and opts.pages > 1 then
        table.insert(vg, TextWidget:new{
            text = T(_("第 %1 / %2 页"), opts.page, opts.pages),
            face = Font:getFace("xx_smallinfofont", 14),
            fgcolor = Blitbuffer.gray(0.4),
        })
    end

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        vg,
    }
end

return M
